terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "name" { type = string }
variable "vpc_cidr" { type = string }
variable "subnets" {
  description = "Map of subnet name -> { cidr, az_index }. Only used when create_vpc = true."
  type        = map(object({ cidr = string, az_index = number }))
  default     = {}
}
variable "create_vpc" {
  type    = bool
  default = true
}
variable "existing_vpc_id" {
  type    = string
  default = null
}
variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "spoke" {
  count                = var.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.name}-vpc" })
}

data "aws_vpc" "existing" {
  count = var.create_vpc ? 0 : 1
  id    = var.existing_vpc_id
}

locals {
  vpc_id = var.create_vpc ? aws_vpc.spoke[0].id : data.aws_vpc.existing[0].id
}

resource "aws_subnet" "this" {
  for_each          = var.create_vpc ? var.subnets : {}
  vpc_id            = local.vpc_id
  cidr_block        = each.value.cidr
  availability_zone = data.aws_availability_zones.available.names[each.value.az_index]
  tags              = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

# The 0.0.0.0/0 -> TGW default route is installed by the tgw module, after
# this VPC's attachment exists.
resource "aws_route_table" "spoke" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = local.vpc_id
  tags   = merge(var.tags, { Name = "${var.name}-rt" })
}

resource "aws_route_table_association" "this" {
  for_each       = aws_subnet.this
  subnet_id      = each.value.id
  route_table_id = aws_route_table.spoke[0].id
}

# Existing-VPC attach path: discover the VPC's subnets so the TGW attachment
# can pick one per AZ. Route tables in an existing VPC remain unmanaged here.
data "aws_subnets" "existing" {
  count = var.create_vpc ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [var.existing_vpc_id]
  }
}

data "aws_subnet" "existing" {
  for_each = var.create_vpc ? toset([]) : toset(data.aws_subnets.existing[0].ids)
  id       = each.value
}

locals {
  created_tgw_subnet_ids = var.create_vpc ? [
    for az in distinct([for s in var.subnets : s.az_index]) :
    [for k, s in var.subnets : aws_subnet.this[k].id if s.az_index == az][0]
  ] : []

  existing_tgw_subnet_ids = var.create_vpc ? [] : [
    for az in distinct([for s in data.aws_subnet.existing : s.availability_zone]) :
    [for s in data.aws_subnet.existing : s.id if s.availability_zone == az][0]
  ]
}

output "vpc_id" { value = local.vpc_id }
output "route_table_id" {
  value = var.create_vpc ? aws_route_table.spoke[0].id : null
}
output "subnet_ids" {
  value = { for k, s in aws_subnet.this : k => s.id }
}
output "tgw_attachment_subnet_ids" {
  value = var.create_vpc ? local.created_tgw_subnet_ids : local.existing_tgw_subnet_ids
}
output "is_managed" { value = var.create_vpc }
