terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "prefix" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
variable "vpc_id" { type = string }
variable "internet_gateway_id" { type = string }
variable "subnet_cidr" {
  description = "Public jump-host subnet carved from the hub VPC (index 7)."
  type        = string
}
variable "instance_type" { type = string }
variable "key_name" { type = string }
variable "admin_source_cidrs" { type = list(string) }

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_subnet" "bastion" {
  vpc_id                  = var.vpc_id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "${var.prefix}-bastion-subnet" })
}

resource "aws_route_table" "bastion" {
  vpc_id = var.vpc_id
  tags   = merge(var.tags, { Name = "${var.prefix}-bastion-rt" })
}

resource "aws_route" "bastion_default_to_igw" {
  route_table_id         = aws_route_table.bastion.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = var.internet_gateway_id
}

resource "aws_route_table_association" "bastion" {
  subnet_id      = aws_subnet.bastion.id
  route_table_id = aws_route_table.bastion.id
}

resource "aws_security_group" "bastion" {
  name        = "${var.prefix}-bastion-sg"
  description = "Operator SSH into the jump host"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.prefix}-bastion-sg" })

  ingress {
    description = "Operator SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_source_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.bastion.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  tags                   = merge(var.tags, { Name = "${var.prefix}-jump" })
}

output "bastion_public_ip" { value = aws_instance.bastion.public_ip }
output "bastion_private_ip" { value = aws_instance.bastion.private_ip }
output "bastion_sg_id" { value = aws_security_group.bastion.id }
output "connect_hint" {
  value = "ssh -J ubuntu@${aws_instance.bastion.public_ip} admin@<FW or Panorama private IP>   # or:  ssh -L 8443:<panorama-private>:443 ubuntu@${aws_instance.bastion.public_ip}"
}
