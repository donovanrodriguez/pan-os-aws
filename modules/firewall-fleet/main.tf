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
  description = "Firewall fleet members keyed by short name (fw1, fw2, ...). Two ENIs each: mgmt (device 0) + GENEVE dataplane (device 1)."
  type = map(object({
    hostname       = string
    mgmt_subnet_id = string
    data_subnet_id = string
    mgmt_ip        = string
    data_ip        = string
  }))
}

variable "mgmt_sg_id" { type = string }
variable "data_sg_id" { type = string }

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

# Dataplane ENI: receives GENEVE-encapsulated flows from the GWLB and the
# target-group health checks. Registered by IP in the GWLB target group.
resource "aws_network_interface" "data" {
  for_each          = local.fws
  subnet_id         = each.value.data_subnet_id
  private_ips       = [each.value.data_ip]
  security_groups   = [var.data_sg_id]
  source_dest_check = false
  tags              = merge(var.tags, { Name = "${each.value.hostname}-data" })
}

# --- IAM: S3 bootstrap read only ---------------------------------------------
# The GWLB design needs no failover permissions: firewall health is handled by
# GWLB health checks and target (de)registration, not by an HA plugin moving
# EIPs/routes. Names are prefixed so parallel deployments never collide.

resource "aws_iam_role" "fw" {
  name = "${var.prefix}-fw-role"
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
  name = "${var.prefix}-fw-bootstrap-read"
  role = aws_iam_role.fw.id

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

resource "aws_iam_instance_profile" "fw" {
  name = "${var.prefix}-fw-instance-profile"
  role = aws_iam_role.fw.name
  tags = var.tags
}

# --- Instances ---------------------------------------------------------------

resource "aws_instance" "fw" {
  for_each             = local.fws
  ami                  = var.ami_id
  instance_type        = var.instance_type
  key_name             = var.key_name
  iam_instance_profile = aws_iam_instance_profile.fw.name
  tags                 = merge(var.tags, { Name = each.value.hostname })

  network_interface {
    network_interface_id = aws_network_interface.mgmt[each.key].id
    device_index         = 0
  }

  network_interface {
    network_interface_id = aws_network_interface.data[each.key].id
    device_index         = 1
  }

  user_data_base64 = base64encode("vmseries-bootstrap-aws-s3bucket=${var.bootstrap_bucket_name}/${each.key}")
}

output "fw_mgmt_ips" {
  value = { for k, fw in local.fws : k => fw.mgmt_ip }
}
output "fw_instance_ids" {
  value = { for k, i in aws_instance.fw : k => i.id }
}
output "fw_data_ips" {
  description = "Dataplane ENI IPs, registered as GWLB target-group IP targets."
  value       = { for k, fw in local.fws : k => fw.data_ip }
}
output "fw_data_eni_ids" {
  value = { for k, eni in aws_network_interface.data : k => eni.id }
}
