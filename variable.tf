variable "project_name" {
  type =  string
}

variable "vpc_cidr" {
  type = string
  default = "10.0.0.0/16"
}

variable "my_ip" {
  type = string
  description = "Define your work public ip range autorized to access aws service"
}

variable "db_username" {
  type = string
}

variable "db_password" {
  type = string
}

variable "db_name" {
  type = string
}