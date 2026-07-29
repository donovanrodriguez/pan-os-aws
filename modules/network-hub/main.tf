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
variable "vpc_cidr" { type = string }
variable "subnets" {
  description = "Hub subnet tiers: key (mgmt_a, untrust_a, trust_a, mgmt_b, untrust_b, trust_b) -> { cidr, az_index }."
  type        = map(object({ cidr = string, az_index = number }))
}
variable "enable_mgmt_nat_gateway" {
  description = "Add a NAT Gateway (in untrust_a) + default route for the mgmt subnets. Used in SCM mode so FW mgmt ENIs can reach the SCM service edge."
  type        = bool
  default     = false
}
variable "mgmt_ingress_cidrs" {
  description = "Source CIDRs allowed to reach Panorama/FW mgmt (443/22). Driven by the chosen mgmt_access_strategy upstream."
  type        = list(string)
  default     = []
}
variable "mgmt_subnet_cidrs" {
  description = "Hub mgmt subnet CIDRs (FW mgmt ENIs live here); allowed to reach Panorama on 3978."
  type        = list(string)
  default     = []
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "hub" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.prefix}-hub-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.hub.id
  tags   = merge(var.tags, { Name = "${var.prefix}-hub-igw" })
}

resource "aws_subnet" "this" {
  for_each          = var.subnets
  vpc_id            = aws_vpc.hub.id
  cidr_block        = each.value.cidr
  availability_zone = data.aws_availability_zones.available.names[each.value.az_index]
  tags              = merge(var.tags, { Name = "${var.prefix}-hub-${replace(each.key, "_", "-")}" })
}

# --- Untrust (public) tier ---------------------------------------------------

resource "aws_route_table" "untrust" {
  vpc_id = aws_vpc.hub.id
  tags   = merge(var.tags, { Name = "${var.prefix}-hub-untrust-rt" })
}

resource "aws_route" "untrust_default_to_igw" {
  route_table_id         = aws_route_table.untrust.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "untrust" {
  for_each       = { for k, s in aws_subnet.this : k => s.id if startswith(k, "untrust") }
  subnet_id      = each.value
  route_table_id = aws_route_table.untrust.id
}

# --- Mgmt tier ---------------------------------------------------------------

resource "aws_route_table" "mgmt" {
  vpc_id = aws_vpc.hub.id
  tags   = merge(var.tags, { Name = "${var.prefix}-hub-mgmt-rt" })
}

resource "aws_route_table_association" "mgmt" {
  for_each       = { for k, s in aws_subnet.this : k => s.id if startswith(k, "mgmt") }
  subnet_id      = each.value
  route_table_id = aws_route_table.mgmt.id
}

resource "aws_eip" "mgmt_nat" {
  count  = var.enable_mgmt_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.prefix}-hub-mgmt-nat-eip" })
}

# NAT GW must live in a public subnet; untrust_a already routes 0/0 -> IGW.
resource "aws_nat_gateway" "mgmt" {
  count         = var.enable_mgmt_nat_gateway ? 1 : 0
  allocation_id = aws_eip.mgmt_nat[0].id
  subnet_id     = aws_subnet.this["untrust_a"].id
  tags          = merge(var.tags, { Name = "${var.prefix}-hub-mgmt-nat" })
  depends_on    = [aws_route.untrust_default_to_igw]
}

resource "aws_route" "mgmt_default_to_nat" {
  count                  = var.enable_mgmt_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.mgmt.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.mgmt[0].id
}

# --- Trust tier (also hosts the TGW attachment ENIs) -------------------------

resource "aws_route_table" "trust" {
  vpc_id = aws_vpc.hub.id
  tags   = merge(var.tags, { Name = "${var.prefix}-hub-trust-rt" })
}

resource "aws_route_table_association" "trust" {
  for_each       = { for k, s in aws_subnet.this : k => s.id if startswith(k, "trust") }
  subnet_id      = each.value
  route_table_id = aws_route_table.trust.id
}

# Spoke-CIDR and on-prem routes -> TGW for the trust + mgmt route tables are
# installed by the tgw module, after the hub VPC attachment exists.

# --- Security groups ---------------------------------------------------------

resource "aws_security_group" "fw_mgmt" {
  name        = "${var.prefix}-fw-mgmt-sg"
  description = "FW mgmt: HTTPS/SSH admin via mgmt_access_strategy"
  vpc_id      = aws_vpc.hub.id
  tags        = merge(var.tags, { Name = "${var.prefix}-fw-mgmt-sg" })

  ingress {
    description = "FW HTTPS admin"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.mgmt_ingress_cidrs
  }

  ingress {
    description = "FW SSH admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.mgmt_ingress_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "fw_untrust" {
  name        = "${var.prefix}-fw-untrust-sg"
  description = "Internet -> firewall untrust (PAN security policy gates traffic)"
  vpc_id      = aws_vpc.hub.id
  tags        = merge(var.tags, { Name = "${var.prefix}-fw-untrust-sg" })

  ingress {
    description = "All inbound; PAN policy is the enforcement point"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "fw_trust" {
  name        = "${var.prefix}-fw-trust-sg"
  description = "Spokes -> firewall trust via TGW"
  vpc_id      = aws_vpc.hub.id
  tags        = merge(var.tags, { Name = "${var.prefix}-fw-trust-sg" })

  ingress {
    description = "All inbound; PAN policy is the enforcement point"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "panorama" {
  name        = "${var.prefix}-panorama-sg"
  description = "Panorama mgmt access + FW registration"
  vpc_id      = aws_vpc.hub.id
  tags        = merge(var.tags, { Name = "${var.prefix}-panorama-sg" })

  ingress {
    description = "Panorama HTTPS admin via mgmt_access_strategy"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.mgmt_ingress_cidrs
  }

  ingress {
    description = "Panorama SSH admin via mgmt_access_strategy"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.mgmt_ingress_cidrs
  }

  ingress {
    description = "Panorama mgmt comms from firewalls"
    from_port   = 3978
    to_port     = 3978
    protocol    = "tcp"
    cidr_blocks = var.mgmt_subnet_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

output "vpc_id" { value = aws_vpc.hub.id }
output "internet_gateway_id" { value = aws_internet_gateway.igw.id }
output "subnet_ids" {
  value = { for k, s in aws_subnet.this : k => s.id }
}
output "trust_subnet_ids" {
  value = [aws_subnet.this["trust_a"].id, aws_subnet.this["trust_b"].id]
}
output "mgmt_subnet_ids" {
  value = [aws_subnet.this["mgmt_a"].id, aws_subnet.this["mgmt_b"].id]
}
output "trust_route_table_id" { value = aws_route_table.trust.id }
output "mgmt_route_table_id" { value = aws_route_table.mgmt.id }
output "mgmt_nat_public_ip" {
  value = var.enable_mgmt_nat_gateway ? aws_eip.mgmt_nat[0].public_ip : null
}
output "fw_mgmt_sg_id" { value = aws_security_group.fw_mgmt.id }
output "fw_untrust_sg_id" { value = aws_security_group.fw_untrust.id }
output "fw_trust_sg_id" { value = aws_security_group.fw_trust.id }
output "panorama_sg_id" { value = aws_security_group.panorama.id }
