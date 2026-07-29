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

variable "fws" {
  description = "Firewall instances keyed by short name (fw1, fw2, ...)."
  type = map(object({
    hostname          = string
    mgmt_subnet_id    = string
    untrust_subnet_id = string
    trust_subnet_id   = string
    mgmt_ip           = string
    untrust_ip        = string
    trust_ip          = string
  }))
}

variable "mgmt_sg_id" { type = string }
variable "untrust_sg_id" { type = string }
variable "trust_sg_id" { type = string }

variable "bootstrap_bucket_name" { type = string }
variable "bootstrap_bucket_arn" { type = string }

locals {
  fws = var.fws
}

resource "aws_network_interface" "mgmt" {
  for_each        = local.fws
  subnet_id       = each.value.mgmt_subnet_id
  private_ips     = [each.value.mgmt_ip]
  security_groups = [var.mgmt_sg_id]
  tags            = merge(var.tags, { Name = "${each.value.hostname}-mgmt" })
}

resource "aws_network_interface" "untrust" {
  for_each          = local.fws
  subnet_id         = each.value.untrust_subnet_id
  private_ips       = [each.value.untrust_ip]
  security_groups   = [var.untrust_sg_id]
  source_dest_check = false
  tags              = merge(var.tags, { Name = "${each.value.hostname}-untrust" })
}

resource "aws_network_interface" "trust" {
  for_each          = local.fws
  subnet_id         = each.value.trust_subnet_id
  private_ips       = [each.value.trust_ip]
  security_groups   = [var.trust_sg_id]
  source_dest_check = false
  tags              = merge(var.tags, { Name = "${each.value.hostname}-trust" })
}

# --- IAM: bootstrap read + HA failover ---------------------------------------
# Names are prefixed so parallel deployments in one account never collide.

resource "aws_iam_role" "fw_ha" {
  name = "${var.prefix}-fw-ha-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "bootstrap_read" {
  name = "${var.prefix}-fw-ha-bootstrap-read"
  role = aws_iam_role.fw_ha.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.bootstrap_bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.bootstrap_bucket_arn}/*"
      },
    ]
  })
}

# Mirrors the OCI dynamic-group policy: the AWS plugin moves secondary IPs,
# the untrust EIP, and rewrites routes on HA failover.
resource "aws_iam_role_policy" "ha_failover" {
  name = "${var.prefix}-fw-ha-failover"
  role = aws_iam_role.fw_ha.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:AssignPrivateIpAddresses",
        "ec2:UnassignPrivateIpAddresses",
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress",
        "ec2:DescribeInstances",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeRouteTables",
        "ec2:ReplaceRoute",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "fw_ha" {
  name = "${var.prefix}-fw-ha-instance-profile"
  role = aws_iam_role.fw_ha.name
  tags = var.tags
}

# --- Instances ---------------------------------------------------------------

resource "aws_instance" "fw" {
  for_each             = local.fws
  ami                  = var.ami_id
  instance_type        = var.instance_type
  key_name             = var.key_name
  iam_instance_profile = aws_iam_instance_profile.fw_ha.name
  tags                 = merge(var.tags, { Name = each.value.hostname })

  network_interface {
    network_interface_id = aws_network_interface.mgmt[each.key].id
    device_index         = 0
  }

  network_interface {
    network_interface_id = aws_network_interface.untrust[each.key].id
    device_index         = 1
  }

  network_interface {
    network_interface_id = aws_network_interface.trust[each.key].id
    device_index         = 2
  }

  user_data_base64 = base64encode("vmseries-bootstrap-aws-s3bucket=${var.bootstrap_bucket_name}/${each.key}")
}

# Public anchor on fw1's untrust ENI (mirrors the OCI reserved public IP; the
# HA plugin re-associates it to the surviving peer on failover).
resource "aws_eip" "fw1_untrust" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.prefix}-fw1-untrust-eip" })
}

resource "aws_eip_association" "fw1_untrust" {
  allocation_id        = aws_eip.fw1_untrust.id
  network_interface_id = aws_network_interface.untrust["fw1"].id
  private_ip_address   = local.fws["fw1"].untrust_ip
}

output "fw_mgmt_ips" {
  value = { for k, fw in local.fws : k => fw.mgmt_ip }
}
output "fw_instance_ids" {
  value = { for k, i in aws_instance.fw : k => i.id }
}
output "fw1_untrust_eip" { value = aws_eip.fw1_untrust.public_ip }
