provider "aws" {
  region = "ca-central-1"
}

locals {
  subnets_list = [for cidr_block in cidrsubnets(var.vpc_cidr, 4, 4, 4) : cidrsubnets(cidr_block, 1, 1)]
}

# reference page:
# https://support.huaweicloud.com/intl/en-us/bestpractice-ecs/en-us_topic_0135015337.html
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

  enable_dns_hostnames = true
  enable_dns_support   = true

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
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "http port"
      cidr_blocks = var.my_ip
    },    
  ]

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      description = "all outbound"
      cidr_blocks = "0.0.0.0/0"
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
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "nginx port"
      source_security_group_id = module.sg_public.this_security_group_id
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "ssh port"
      source_security_group_id = module.sg_public.this_security_group_id
    },
  ]

  ingress_with_self = [
    {
      from_port   = 2049
      to_port     = 2049
      protocol    = "tcp"
      description = "efs"
      self        = true
    },
  ]

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      description = "all outbound"
      cidr_blocks = "0.0.0.0/0"
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

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      description = "all outbound"
      cidr_blocks = "0.0.0.0/0"
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

  name     = var.db_name
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

  min_size                  = 1
  max_size                  = 4
  desired_capacity          = 2
  wait_for_capacity_timeout = 0
  health_check_type         = "EC2"
  vpc_zone_identifier       = module.vpc.private_subnets

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
  key_name = "key-hr123000"
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

  iam_instance_profile_name = aws_iam_instance_profile.this.name

  user_data_base64 = base64encode(<<-EOF
#!/bin/bash
# set timezone
sudo sed -i 's%UTC%America/Toronto%g' /etc/sysconfig/clock
sudo ln -sf /usr/share/zoneinfo/America/Toronto /etc/localtime
# install nginx
sudo wget http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm
sudo rpm -ivh nginx-release-centos-7-0.el7.ngx.noarch.rpm
sudo yum -y install nginx
# install php-fpm
sudo rpm -Uvh https://mirror.webtatic.com/yum/el7/epel-release.rpm
sudo rpm -Uvh https://mirror.webtatic.com/yum/el7/webtatic-release.rpm
sudo yum -y install php70w-tidy php70w-common php70w-devel php70w-pdo php70w-mysql php70w-gd php70w-ldap php70w-mbstring php70w-mcrypt php70w-fpm
sudo systemctl start php-fpm
# modify nginx configuration
sudo sed -i 's%index  index.html index.htm%index  index.php index.html index.htm%g' /etc/nginx/conf.d/default.conf
sudo sed -i '29,35 s/#//g' /etc/nginx/conf.d/default.conf
sudo sed -i '33 s%/scripts$fastcgi_script_name;%/usr/share/nginx/html$fastcgi_script_name;%1' /etc/nginx/conf.d/default.conf
# install mysql-client
sudo rpm -Uvh http://dev.mysql.com/get/mysql57-community-release-el7-8.noarch.rpm
sudo yum -y install mysql-community-client
# mount nfs
sudo yum install -y amazon-efs-utils
sudo mount -t efs ${aws_efs_file_system.this.id}:/ /usr/share/nginx/html/
sudo chmod 777 /usr/share/nginx/html/
# install wordpress
if [ ! -e /usr/share/nginx/html/wordpress ]
then
echo "<h1>efs-wordpress-project</>" | sudo tee /usr/share/nginx/html/index.html
sudo wget https://wordpress.org/wordpress-4.9.8.tar.gz
sudo tar -xvf wordpress-4.9.8.tar.gz -C /usr/share/nginx/html/
sudo chmod -R 777 /usr/share/nginx/html/
fi
# start nginx
sudo systemctl start nginx
EOF
)

  depends_on = [
      aws_efs_mount_target.this
    ]

}


###########################################################################
#
# Create a efs storage for instacences of asg to install wordpress files.
#
###########################################################################
resource "random_id" "nfs" {
  byte_length = 8
}

resource "aws_efs_file_system" "this" {
  creation_token = "tf-nfs-demo-${random_id.nfs.hex}"

  lifecycle_policy {
    # AFTER_7_DAYS, AFTER_14_DAYS, AFTER_30_DAYS, AFTER_60_DAYS, or AFTER_90_DAYS
    transition_to_ia = "AFTER_30_DAYS"
  }

  # Can be either "generalPurpose" or "maxIO"
  performance_mode = "generalPurpose"

  # Valid values: bursting, provisioned. When using provisioned, also set provisioned_throughput_in_mibps
  throughput_mode = "bursting"
  #provisioned_throughput_in_mibps = 

  # option pour encryption
  encrypted = false
  kms_key_id = null

  tags = {
    Name = "tf-efs-demo-${random_id.nfs.hex}"
  }
}

resource "aws_efs_mount_target" "this" {
  count = length(module.vpc.private_subnets)

  file_system_id = aws_efs_file_system.this.id
  subnet_id      = module.vpc.private_subnets[count.index]

  security_groups = [module.sg_private.this_security_group_id]
}


resource "aws_efs_file_system_policy" "this" {
  file_system_id = aws_efs_file_system.this.id

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Id": "efs-policy-wizard-244d7785-a7b4-4cb3-97e6-361483b1abfd",
    "Statement": [
        {
            "Sid": "efs-statement-332e2306-238c-4e2e-9861-a9813c4ebd1d",
            "Effect": "Allow",
            "Principal": {
                "AWS": "*"
            },
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientRootAccess"
            ],
            "Condition": {
                "Bool": {
                    "elasticfilesystem:AccessedViaMountTarget": "true"
                }
            }
        }
    ]
}
POLICY
}

resource "aws_iam_role" "this" {
  name = "efs-test-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "this" {
  name        = "efs-test-policy"
  description = "A test policy"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "elasticfilesystem:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "efs-attach" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}

resource "aws_iam_instance_profile" "this" {
  name = "efs-test-profile"
  role = aws_iam_role.this.name
}

###########################################################################
#
# Create a bastion instance in the public subnet.
#
###########################################################################

resource "aws_instance" "bastion" {

  #required parametres
  ami           = data.aws_ami.amz2.id
  instance_type = "t2.micro"

  #optional parametres
  associate_public_ip_address = true
  key_name = "key-hr123000" #key paire name exists in aws.

  vpc_security_group_ids = [module.sg_public.this_security_group_id]

  subnet_id = module.vpc.public_subnets[0]

  tags = {
    Name = "tf-lnmp-bastionVM"
  }

}

###########################################################################
#
# Create an application load balancer in the public subnet.
#
###########################################################################

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 5.0"

  name = var.project_name

  load_balancer_type = "application"

  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.sg_public.this_security_group_id]

  target_groups = [
    {
      name_prefix      = "tf-wp"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
      stickiness = {
        enabled = true
        cookie_duration = 3600
        type = "lb_cookie"
      }
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
      action_type        = "forward"
    }
  ]

  tags = {
    Environment = "Test"
  }
}

resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = module.asg.autoscaling_group_id
  alb_target_group_arn   = module.alb.target_group_arns[0]
}
