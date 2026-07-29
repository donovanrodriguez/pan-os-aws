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
variable "data_subnet_ids" {
  description = "Hub data subnets (one per AZ) hosting the GWLB nodes alongside the firewall dataplane ENIs."
  type        = list(string)
}
variable "gwlbe_subnets" {
  description = "Dedicated GWLB-endpoint subnets keyed by AZ suffix (a, b) -> subnet ID. One endpoint per AZ."
  type        = map(string)
}
variable "fw_data_ips" {
  description = "Firewall dataplane ENI IPs keyed by fw short name; each becomes a GENEVE target."
  type        = map(string)
}
variable "trust_route_table_ids" {
  description = "Per-AZ route tables of the TGW-attachment (trust) subnets; each gets 0.0.0.0/0 -> the AZ-local GWLBe."
  type        = map(string)
}
variable "egress_route_table_ids" {
  description = "Per-AZ route tables of the egress (NAT) subnets; each gets spoke CIDRs -> the AZ-local GWLBe so de-NATed return traffic is re-inspected."
  type        = map(string)
}
variable "spoke_cidrs" {
  description = "Protected spoke CIDRs (drives the egress-rt return routes)."
  type        = list(string)
  default     = []
}

# --- Gateway Load Balancer ---------------------------------------------------

# Cross-zone stays on so a single-firewall fleet (fw_count = 1) or a full-AZ
# firewall outage does not blackhole the other AZ's GWLBe. GWLB flow stickiness
# (5-tuple hash) still pins both directions of a flow to one firewall.
resource "aws_lb" "gwlb" {
  name                             = "${var.prefix}-gwlb"
  load_balancer_type               = "gateway"
  subnets                          = var.data_subnet_ids
  enable_cross_zone_load_balancing = true
  tags                             = merge(var.tags, { Name = "${var.prefix}-gwlb" })
}

# Health checks: PAN documents that the GWLB target group cannot use HTTP
# against the VM-Series (unsecured protocol is refused); HTTPS or TCP are the
# supported options, so TCP/443 is used here. The dataplane interface
# (ethernet1/1) must carry an interface-management profile permitting HTTPS
# for the probe to succeed.
resource "aws_lb_target_group" "fw" {
  name        = "${var.prefix}-fw-tg"
  port        = 6081
  protocol    = "GENEVE"
  target_type = "ip"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.prefix}-fw-tg" })

  health_check {
    protocol = "TCP"
    port     = 443
  }
}

resource "aws_lb_target_group_attachment" "fw" {
  for_each         = var.fw_data_ips
  target_group_arn = aws_lb_target_group.fw.arn
  target_id        = each.value
}

resource "aws_lb_listener" "gwlb" {
  load_balancer_arn = aws_lb.gwlb.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.fw.arn
  }

  tags = var.tags
}

# --- Endpoint service + per-AZ endpoints -------------------------------------

resource "aws_vpc_endpoint_service" "gwlb" {
  acceptance_required        = false
  gateway_load_balancer_arns = [aws_lb.gwlb.arn]
  tags                       = merge(var.tags, { Name = "${var.prefix}-gwlb-endpoint-service" })
}

resource "aws_vpc_endpoint" "gwlbe" {
  for_each          = var.gwlbe_subnets
  service_name      = aws_vpc_endpoint_service.gwlb.service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  vpc_id            = var.vpc_id
  subnet_ids        = [each.value]
  tags              = merge(var.tags, { Name = "${var.prefix}-gwlbe-${each.key}" })
}

# --- Routes targeting the GWLB endpoints -------------------------------------
# Created here (next to the endpoints) so they sequence after the endpoint
# exists, mirroring how the tgw module owns its attachment-dependent routes.
# Every route stays AZ-local: with TGW appliance mode this keeps both flow
# directions in one AZ and therefore on one stateful firewall.

# TGW-attachment (trust) subnets: everything arriving from the TGW goes to
# inspection first.
resource "aws_route" "trust_default_to_gwlbe" {
  for_each               = var.trust_route_table_ids
  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[each.key].id
}

locals {
  egress_spoke_routes = {
    for pair in setproduct(keys(var.egress_route_table_ids), var.spoke_cidrs) :
    "${pair[0]}-${pair[1]}" => { az = pair[0], cidr = pair[1] }
  }
}

# Egress (NAT) subnets: de-NATed internet return traffic bound for a spoke
# re-enters inspection via the AZ-local GWLBe (standard AWS centralized-egress
# layout; sending it straight to the TGW would bypass the firewalls on the
# return leg).
resource "aws_route" "egress_spoke_to_gwlbe" {
  for_each               = local.egress_spoke_routes
  route_table_id         = var.egress_route_table_ids[each.value.az]
  destination_cidr_block = each.value.cidr
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[each.value.az].id
}

output "endpoint_service_name" {
  value = aws_vpc_endpoint_service.gwlb.service_name
}
output "gwlbe_ids" {
  value = { for k, e in aws_vpc_endpoint.gwlbe : k => e.id }
}
output "gwlb_arn" { value = aws_lb.gwlb.arn }
output "target_group_arn" { value = aws_lb_target_group.fw.arn }
