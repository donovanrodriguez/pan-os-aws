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
variable "ami_id" { type = string }
variable "instance_type" { type = string }
variable "key_name" { type = string }
variable "log_volume_gb" { type = number }
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }
variable "private_ip" { type = string }

resource "aws_network_interface" "mgmt" {
  subnet_id       = var.subnet_id
  private_ips     = [var.private_ip]
  security_groups = [var.security_group_id]
  tags            = merge(var.tags, { Name = "${var.prefix}-panorama-mgmt" })
}

resource "aws_instance" "panorama" {
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name
  tags          = merge(var.tags, { Name = "${var.prefix}-panorama" })

  network_interface {
    network_interface_id = aws_network_interface.mgmt.id
    device_index         = 0
  }
}

resource "aws_ebs_volume" "panorama_logs" {
  availability_zone = aws_instance.panorama.availability_zone
  size              = var.log_volume_gb
  type              = "gp3"
  tags              = merge(var.tags, { Name = "${var.prefix}-panorama-logs" })
}

resource "aws_volume_attachment" "panorama_logs" {
  device_name = "/dev/sdb"
  volume_id   = aws_ebs_volume.panorama_logs.id
  instance_id = aws_instance.panorama.id
}

output "instance_id" { value = aws_instance.panorama.id }
output "private_ip" { value = var.private_ip }
