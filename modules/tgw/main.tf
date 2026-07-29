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
variable "hub_vpc_id" { type = string }
variable "hub_attachment_subnet_ids" {
  description = "Hub subnets hosting the TGW attachment ENIs (= trust subnets, one per AZ); their route tables force everything through the AZ-local GWLBe."
  type        = list(string)
}
variable "hub_gwlbe_route_table_ids" {
  description = "Per-AZ hub GWLBe-subnet route tables: each receives per-spoke CIDR + on-prem routes -> TGW so post-inspection traffic returns to the TGW (created here so they order after the hub attachment)."
  type        = map(string)
}
variable "hub_mgmt_route_table_id" {
  description = "Hub mgmt route table: receives on-prem routes -> TGW for the ipsec_vpn mgmt strategy."
  type        = string
}
variable "spokes" {
  description = "Map of protected spokes: key = short name, value = { vpc_id, subnet_ids (one per AZ), cidr }."
  type = map(object({
    vpc_id     = string
    subnet_ids = list(string)
    cidr       = string
  }))
  default = {}
}
variable "spoke_route_table_ids" {
  description = "Route table IDs of managed spokes; each gets a default 0.0.0.0/0 route -> TGW (created here so they order after that spoke's attachment)."
  type        = map(string)
  default     = {}
}
variable "enable_vpn_routing" {
  description = "Associate the site-to-site VPN attachment with the spoke route table and install on-prem routes in hub-rt."
  type        = bool
  default     = false
}
variable "vpn_attachment_id" {
  description = "TGW attachment ID of the aws_vpn_connection. Required when enable_vpn_routing is true."
  type        = string
  default     = null
}
variable "vpn_on_prem_cidrs" {
  description = "On-prem CIDRs reachable via VPN. Installed in hub-rt -> VPN attachment; spokes reach them via the hub firewall (spoke-rt default route)."
  type        = list(string)
  default     = []
}

resource "aws_ec2_transit_gateway" "this" {
  description                     = "${var.prefix} hub-and-spoke inspection TGW"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  tags                            = merge(var.tags, { Name = "${var.prefix}-tgw" })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = var.hub_vpc_id
  subnet_ids         = var.hub_attachment_subnet_ids

  # Keep flows AZ-symmetric through the stateful firewalls.
  appliance_mode_support = "enable"

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, { Name = "${var.prefix}-tgw-hub-attachment" })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke" {
  for_each           = var.spokes
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = each.value.vpc_id
  subnet_ids         = each.value.subnet_ids

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, { Name = "${var.prefix}-tgw-spoke-${each.key}-attachment" })
}

resource "aws_ec2_transit_gateway_route_table" "hub_rt" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.prefix}-tgw-hub-rt" })
}

resource "aws_ec2_transit_gateway_route_table" "spoke_rt" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.prefix}-tgw-spoke-rt" })
}

resource "aws_ec2_transit_gateway_route_table_association" "hub" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_rt.id
}

resource "aws_ec2_transit_gateway_route_table_association" "spoke" {
  for_each                       = var.spokes
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_rt.id
}

# Everything leaving a spoke lands in the hub (firewall trust tier). East-west
# spoke-to-spoke traffic therefore hairpins through the firewall.
resource "aws_ec2_transit_gateway_route" "spoke_default_to_hub" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_rt.id
}

resource "aws_ec2_transit_gateway_route" "hub_to_spoke" {
  for_each                       = var.spokes
  destination_cidr_block         = each.value.cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_rt.id
}

# VPN attachment joins the spoke route table: on-prem traffic is treated like a
# spoke (default path into the hub firewall).
resource "aws_ec2_transit_gateway_route_table_association" "vpn" {
  count                          = var.enable_vpn_routing ? 1 : 0
  transit_gateway_attachment_id  = var.vpn_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_rt.id
}

resource "aws_ec2_transit_gateway_route" "hub_to_onprem" {
  for_each                       = var.enable_vpn_routing ? toset(var.vpn_on_prem_cidrs) : toset([])
  destination_cidr_block         = each.value
  transit_gateway_attachment_id  = var.vpn_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_rt.id
}

# --- VPC routes targeting the TGW -------------------------------------------
# AWS rejects a VPC route pointing at a TGW the VPC is not attached to, so
# these live here (next to the attachments) instead of in the network modules.

resource "aws_route" "spoke_default_to_tgw" {
  for_each               = var.spoke_route_table_ids
  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.spoke]
}

# Return path: post-inspection traffic re-emerging at a GWLBe and bound for a
# spoke (or on-prem) is handed back to the TGW. One route per AZ-local GWLBe
# route table keeps the hop AZ-symmetric with appliance mode.
locals {
  gwlbe_spoke_routes = {
    for pair in setproduct(keys(var.hub_gwlbe_route_table_ids), keys(var.spokes)) :
    "${pair[0]}-${pair[1]}" => {
      az   = pair[0]
      cidr = var.spokes[pair[1]].cidr
    }
  }

  gwlbe_onprem_routes = {
    for pair in setproduct(keys(var.hub_gwlbe_route_table_ids), var.enable_vpn_routing ? var.vpn_on_prem_cidrs : []) :
    "${pair[0]}-${pair[1]}" => {
      az   = pair[0]
      cidr = pair[1]
    }
  }
}

resource "aws_route" "hub_gwlbe_to_spoke" {
  for_each               = local.gwlbe_spoke_routes
  route_table_id         = var.hub_gwlbe_route_table_ids[each.value.az]
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route" "hub_gwlbe_to_onprem" {
  for_each               = local.gwlbe_onprem_routes
  route_table_id         = var.hub_gwlbe_route_table_ids[each.value.az]
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route" "hub_mgmt_to_onprem" {
  for_each               = var.enable_vpn_routing ? toset(var.vpn_on_prem_cidrs) : toset([])
  route_table_id         = var.hub_mgmt_route_table_id
  destination_cidr_block = each.value
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

output "tgw_id" { value = aws_ec2_transit_gateway.this.id }
output "hub_attachment_id" { value = aws_ec2_transit_gateway_vpc_attachment.hub.id }
output "spoke_attachment_ids" {
  value = { for k, a in aws_ec2_transit_gateway_vpc_attachment.spoke : k => a.id }
}
