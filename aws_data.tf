###########################################################################
#
# Use this data source to get datas from aws for other resources.
#
###########################################################################

# get amazon linux 2's ami id
data "aws_ami" "amz2" {
  most_recent = true
  owners      = ["amazon"] # Canonical

  # more filter conditions are describled in the followed web link
  # https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-images.html
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-2.0.*-x86_64-gp2"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name = "architecture"
    values = ["x86_64"]
  }
}

# get az from the current region
data "aws_availability_zones" "available_zones" {
  state = "available"
  exclude_names = ["ca-central-1d"] # exclude zone 1d because it does not support t2.micro
}

data "aws_caller_identity" "current" {} #data.aws_caller_identity.current.account_id