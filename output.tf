output "bastion_ip" {
  value = aws_instance.bastion.public_ip
}

output "alb_hostname" {
  value = module.alb.this_lb_dns_name
}