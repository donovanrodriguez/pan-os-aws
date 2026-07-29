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
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "subnet_ids" {
  description = "Hub mgmt subnets that host the SSM interface endpoints."
  type        = list(string)
}

resource "aws_security_group" "ssm_endpoints" {
  name        = "${var.prefix}-ssm-endpoints-sg"
  description = "HTTPS to the SSM interface endpoints from inside the hub VPC"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.prefix}-ssm-endpoints-sg" })

  ingress {
    description = "Endpoint HTTPS from the hub VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Session Manager needs all three endpoints reachable from the target's subnet
# so instances without public IPs or NAT can register with SSM.
resource "aws_vpc_endpoint" "ssm" {
  for_each            = toset(["ssm", "ssmmessages", "ec2messages"])
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.prefix}-${each.value}-endpoint" })
}

output "endpoint_ids" {
  value = { for k, e in aws_vpc_endpoint.ssm : k => e.id }
}
output "endpoint_sg_id" { value = aws_security_group.ssm_endpoints.id }
