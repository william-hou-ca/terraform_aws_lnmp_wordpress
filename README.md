# terraform_aws_lnmp_wordpress
  A wordpress project includes the following modules:
  1. Create an vpc including public subnets, private subnets et database subnets
  2. Create security groups for public subnets, private subnets et database subnets
  3. Create mysql databases
  4. Create autoscaling group of ec2 instances served as web servers
  5. Create a efs storage for instacences of asg to install wordpress files.
  6. Create a bastion instance in the public subnet.
  7. Create an application load balancer in the public subnet.
  
  When you access the alb dns name, a simple web page will show. To access wordpress web site, please use the following address: http://alb_dns_name/wordpress/