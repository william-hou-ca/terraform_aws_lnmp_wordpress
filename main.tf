provider "aws" {
  region = "ca-central-1"
}

locals {
  subnets_list = [for cidr_block in cidrsubnets(var.vpc_cidr, 4, 4, 4) : cidrsubnets(cidr_block, 1, 1)]
}

###########################################################################
#
# Create an vpc including public subnets, private subnets et database subnets
#
###########################################################################

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "vpc-${var.project_name}"
  cidr = var.vpc_cidr

  azs             = data.aws_availability_zones.available_zones.names
  public_subnets =  local.subnets_list[0]
  private_subnets  = local.subnets_list[1]
  database_subnets = local.subnets_list[2]

  enable_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Terraform = "true"
    Environment = "dev"
    project = var.project_name
  }
}

###########################################################################
#
# Create security groups for public subnets, private subnets et database subnets
#
###########################################################################

module "sg_public" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "${var.project_name}-sg-public"
  description = "Security group for public subnets"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "http port"
      cidr_blocks = var.vpc_cidr
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "ssh port"
      cidr_blocks = var.my_ip
    },
  ]
}

module "sg_private" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "${var.project_name}-sg-private"
  description = "Security group for private subnets"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "ssh port"
      cidr_blocks = var.vpc_cidr
    },
  ]

  ingress_with_source_security_group_id = [
    {
      from_port   = 9000
      to_port     = 9000
      protocol    = "tcp"
      description = "php-fpm port"
      source_security_group_id = module.sg_public.this_security_group_id
    },
  ]
}

module "sg_db" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "${var.project_name}-sg-db"
  description = "Security group for db subnets"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "mysql port"
      source_security_group_id = module.sg_private.this_security_group_id
    },
  ]
}

###########################################################################
#
# Create mysql databases
#
###########################################################################

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 2.0"

  identifier = "${var.project_name}-db-mysql"

  engine            = "mysql"
  engine_version    = "5.7.33"
  instance_class    = "db.t2.micro"
  allocated_storage = 5

  name     = "dbwordpress"
  username = var.db_username
  password = var.db_password
  port     = "3306"

  iam_database_authentication_enabled = false


  vpc_security_group_ids = [module.sg_db.this_security_group_id]

  maintenance_window = "Mon:00:00-Mon:03:00"
  backup_window      = "03:00-06:00"

  tags = {
    Owner       = "user"
    Environment = "dev"
  }

  multi_az = false

  # Backups are required in order to create a replica
  backup_retention_period = 0
  skip_final_snapshot     = true

  # DB subnet group
  subnet_ids = module.vpc.database_subnets
  #create_db_subnet_group = false
  #db_subnet_group_name   = module.vpc.database_subnet_group_name

  # DB parameter group
  family = "mysql5.7"

  # DB option group
  major_engine_version = "5.7"

  # Database Deletion Protection
  deletion_protection = false

  parameters = [
    {
      name = "character_set_client"
      value = "utf8mb4"
    },
    {
      name = "character_set_server"
      value = "utf8mb4"
    }
  ]

}

###########################################################################
#
# Create autoscaling group
#
###########################################################################

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 4.0"

  # Autoscaling group
  name = "${var.project_name}-asg"

  min_size                  = 0
  max_size                  = 2
  desired_capacity          = 1
  wait_for_capacity_timeout = 0
  health_check_type         = "EC2"
  vpc_zone_identifier       = module.vpc.private_subnets

  initial_lifecycle_hooks = [
    {
      name                  = "ExampleStartupLifeCycleHook"
      default_result        = "CONTINUE"
      heartbeat_timeout     = 60
      lifecycle_transition  = "autoscaling:EC2_INSTANCE_LAUNCHING"
      notification_metadata = jsonencode({ "hello" = "world" })
    },
    {
      name                  = "ExampleTerminationLifeCycleHook"
      default_result        = "CONTINUE"
      heartbeat_timeout     = 180
      lifecycle_transition  = "autoscaling:EC2_INSTANCE_TERMINATING"
      notification_metadata = jsonencode({ "goodbye" = "world" })
    }
  ]

  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }

  # Launch template
  lt_name                = "${var.project_name}-asg"
  description            = "Launch template example"
  update_default_version = true

  use_lt    = true
  create_lt = true

  image_id          = data.aws_ami.amz2.id
  instance_type     = "t2.micro"
  ebs_optimized     = false
  enable_monitoring = false

  block_device_mappings = [
    {
      # Root volume
      device_name = "/dev/xvda"
      no_device   = 0
      ebs = {
        delete_on_termination = true
        encrypted             = true
        volume_size           = 8
        volume_type           = "gp2"
      }
    }
  ]

  capacity_reservation_specification = {
    capacity_reservation_preference = "open"
  }

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 32
  }

  network_interfaces = [
    {
      delete_on_termination = true
      description           = "eth0"
      device_index          = 0
      security_groups       = [module.sg_private.this_security_group_id]
    }
  ]

  tags = [
    {
      key                 = "Environment"
      value               = "dev"
      propagate_at_launch = true
    },
    {
      key                 = "Project"
      value               = "wordpress"
      propagate_at_launch = true
    },
  ]

}

/*
https://support.huaweicloud.com/intl/en-us/bestpractice-ecs/en-us_topic_0135015337.html


sudo wget http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm
sudo rpm -ivh nginx-release-centos-7-0.el7.ngx.noarch.rpm
sudo yum -y install nginx
sudo systemctl start nginx

#sudo rpm -Uvh http://dev.mysql.com/get/mysql57-community-release-el7-8.noarch.rpm
#sudo yum -y install mysql-community-server
#sudo systemctl start mysqld
#sudo grep 'temporary password' /var/log/mysqld.log
#sudo mysql_secure_installation

sudo rpm -Uvh https://mirror.webtatic.com/yum/el7/epel-release.rpm
sudo rpm -Uvh https://mirror.webtatic.com/yum/el7/webtatic-release.rpm
sudo yum -y install php70w-tidy php70w-common php70w-devel php70w-pdo php70w-mysql php70w-gd php70w-ldap php70w-mbstring php70w-mcrypt php70w-fpm
sudo systemctl start php-fpm

sudo sed -i 's%index  index.html index.htm%index  index.php index.html index.htm%g' /etc/nginx/conf.d/default.conf
sudo sed -i '29,35 s/#//g' /etc/nginx/conf.d/default.conf
sudo sed -i '33 s%/scripts$fastcgi_script_name;%/usr/share/nginx/html$fastcgi_script_name;%1' default.conf
sudo service nginx reload


CREATE DATABASE wordpress;
GRANT ALL ON wordpress.* TO wordpressuser@localhost IDENTIFIED BY 'Wordpress@123';
FLUSH PRIVILEGES;


sudo wget https://wordpress.org/wordpress-4.9.8.tar.gz
sudo tar -xvf wordpress-4.9.8.tar.gz -C /usr/share/nginx/html/
sudo chmod -R 777 /usr/share/nginx/html/wordpress

#testblog admin (t2dC$UAlcDTaO$RH@






*/