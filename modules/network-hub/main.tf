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
  description = "Hub subnet tiers keyed <tier>_<az> (mgmt, data, trust, gwlbe, egress x a/b) -> { cidr, az_index }."
  type        = map(object({ cidr = string, az_index = number }))
}
variable "enable_mgmt_nat_route" {
  description = "Add a default route from the mgmt route table to the AZ-a egress NAT gateway. Used in SCM mode so FW mgmt ENIs can reach the SCM service edge."
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

locals {
  # The hub tiers are striped across exactly two AZs (a = az_index 0,
  # b = az_index 1); per-AZ route tables key off these suffixes.
  azs = toset(["a", "b"])

  data_subnet_cidrs = [for k, s in var.subnets : s.cidr if startswith(k, "data")]
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

# --- Egress (public NAT) tier ------------------------------------------------
# Purpose: hosts the per-AZ NAT gateways. Inspected internet-bound traffic
# arrives here from the AZ-local GWLBe, is SNATed, and exits the IGW. Return
# traffic de-NATed by the NAT GW is sent back to the AZ-local GWLBe for
# re-inspection (spoke-CIDR routes installed by the gwlb module).

resource "aws_route_table" "egress" {
  for_each = local.azs
  vpc_id   = aws_vpc.hub.id
  tags     = merge(var.tags, { Name = "${var.prefix}-hub-egress-${each.key}-rt" })
}

resource "aws_route" "egress_default_to_igw" {
  for_each               = local.azs
  route_table_id         = aws_route_table.egress[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "egress" {
  for_each       = local.azs
  subnet_id      = aws_subnet.this["egress_${each.key}"].id
  route_table_id = aws_route_table.egress[each.key].id
}

resource "aws_eip" "nat" {
  for_each = local.azs
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "${var.prefix}-hub-nat-${each.key}-eip" })
}

# One NAT gateway per AZ so the post-inspection egress hop never crosses AZs
# (symmetric with TGW appliance mode on the hub attachment).
resource "aws_nat_gateway" "nat" {
  for_each      = local.azs
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this["egress_${each.key}"].id
  tags          = merge(var.tags, { Name = "${var.prefix}-hub-nat-${each.key}" })
  depends_on    = [aws_route.egress_default_to_igw]
}

# --- GWLB endpoint tier ------------------------------------------------------
# Purpose: dedicated per-AZ subnets for the GatewayLoadBalancer VPC endpoints.
# Post-inspection traffic re-emerges here; this route table decides where it
# goes next: internet-bound -> AZ-local NAT GW (below); spoke/on-prem-bound ->
# TGW (routes installed by the tgw module after the hub attachment exists).

resource "aws_route_table" "gwlbe" {
  for_each = local.azs
  vpc_id   = aws_vpc.hub.id
  tags     = merge(var.tags, { Name = "${var.prefix}-hub-gwlbe-${each.key}-rt" })
}

resource "aws_route" "gwlbe_default_to_nat" {
  for_each               = local.azs
  route_table_id         = aws_route_table.gwlbe[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat[each.key].id
}

resource "aws_route_table_association" "gwlbe" {
  for_each       = local.azs
  subnet_id      = aws_subnet.this["gwlbe_${each.key}"].id
  route_table_id = aws_route_table.gwlbe[each.key].id
}

# --- Data (firewall dataplane + GWLB) tier -----------------------------------
# Purpose: hosts the GWLB nodes and the firewall dataplane ENIs. All GENEVE
# traffic between them is intra-subnet, so only the implicit local route is
# needed; the tier stays fully private.

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.hub.id
  tags   = merge(var.tags, { Name = "${var.prefix}-hub-data-rt" })
}

resource "aws_route_table_association" "data" {
  for_each       = { for k, s in aws_subnet.this : k => s.id if startswith(k, "data") }
  subnet_id      = each.value
  route_table_id = aws_route_table.data.id
}

# --- Mgmt tier ---------------------------------------------------------------
# Purpose: FW mgmt ENIs + Panorama. Private; optional 0/0 -> NAT for SCM mode
# (service-edge reachability); on-prem routes -> TGW installed by the tgw
# module for the ipsec_vpn mgmt strategy.

resource "aws_route_table" "mgmt" {
  vpc_id = aws_vpc.hub.id
  tags   = merge(var.tags, { Name = "${var.prefix}-hub-mgmt-rt" })
}

resource "aws_route_table_association" "mgmt" {
  for_each       = { for k, s in aws_subnet.this : k => s.id if startswith(k, "mgmt") }
  subnet_id      = each.value
  route_table_id = aws_route_table.mgmt.id
}

# Mgmt is one shared route table across both AZs, so SCM-bound mgmt egress
# pins to the AZ-a NAT gateway. Acceptable for the low-volume mgmt plane.
resource "aws_route" "mgmt_default_to_nat" {
  count                  = var.enable_mgmt_nat_route ? 1 : 0
  route_table_id         = aws_route_table.mgmt.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat["a"].id
}

# --- Trust (TGW attachment) tier ---------------------------------------------
# Purpose: hosts the TGW attachment ENIs only. Everything the TGW delivers
# into the hub is forced through inspection: per-AZ 0/0 -> AZ-local GWLBe
# routes are installed by the gwlb module after the endpoints exist.

resource "aws_route_table" "trust" {
  for_each = local.azs
  vpc_id   = aws_vpc.hub.id
  tags     = merge(var.tags, { Name = "${var.prefix}-hub-trust-${each.key}-rt" })
}

resource "aws_route_table_association" "trust" {
  for_each       = local.azs
  subnet_id      = aws_subnet.this["trust_${each.key}"].id
  route_table_id = aws_route_table.trust[each.key].id
}

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

# GWLB nodes live in the data subnets, so both GENEVE and health-check probes
# source from the data subnet CIDRs.
resource "aws_security_group" "fw_data" {
  name        = "${var.prefix}-fw-data-sg"
  description = "GWLB -> firewall dataplane: GENEVE + TCP health checks"
  vpc_id      = aws_vpc.hub.id
  tags        = merge(var.tags, { Name = "${var.prefix}-fw-data-sg" })

  ingress {
    description = "GENEVE-encapsulated traffic from the GWLB"
    from_port   = 6081
    to_port     = 6081
    protocol    = "udp"
    cidr_blocks = local.data_subnet_cidrs
  }

  ingress {
    description = "GWLB target-group health checks (TCP/443)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.data_subnet_cidrs
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
output "data_subnet_ids" {
  value = [aws_subnet.this["data_a"].id, aws_subnet.this["data_b"].id]
}
output "gwlbe_subnet_ids" {
  value = { for az in local.azs : az => aws_subnet.this["gwlbe_${az}"].id }
}
output "trust_route_table_ids" {
  value = { for az, rt in aws_route_table.trust : az => rt.id }
}
output "gwlbe_route_table_ids" {
  value = { for az, rt in aws_route_table.gwlbe : az => rt.id }
}
output "egress_route_table_ids" {
  value = { for az, rt in aws_route_table.egress : az => rt.id }
}
output "mgmt_route_table_id" { value = aws_route_table.mgmt.id }
output "nat_public_ips" {
  value = { for az, eip in aws_eip.nat : az => eip.public_ip }
}
output "fw_mgmt_sg_id" { value = aws_security_group.fw_mgmt.id }
output "fw_data_sg_id" { value = aws_security_group.fw_data.id }
output "panorama_sg_id" { value = aws_security_group.panorama.id }
