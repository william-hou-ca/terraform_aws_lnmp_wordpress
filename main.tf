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

  multi_az = true

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

/*
sudo amazon-linux-extras install nginx1 -y
sudo amazon-linux-extras install epel -y
sudo amazon-linux-extras install php7.4 -y
sudo systemctl start nginx
sudo wget https://wordpress.org/wordpress-4.9.7.tar.gz
sudo tar -zxvf wordpress-4.9.7.tar.gz -C /usr/share/nginx/html
sudo chown -R nginx:nginx /usr/share/nginx/html/wordpress/
sudo sed -i 's%/usr/share/nginx/html%/usr/share/nginx/html/wordpress%g' /etc/nginx/nginx.conf
sudo systemctl restart nginx

cat<<EOF | sudo tee -a /usr/share/nginx/html/wordpress/wp-config.php
define('DB_NAME', 'wordpress');
define('DB_USER', 'root');
define('DB_PASSWORD', 'root123');
define('DB_HOST', 'localhost');
EOF


*/