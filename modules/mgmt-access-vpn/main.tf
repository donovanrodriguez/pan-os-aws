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
variable "transit_gateway_id" { type = string }
variable "vpn_config" {
  description = "Parsed YAML VPN config. Required fields: cpe_public_ip (string), on_prem_cidrs (list of CIDRs). Optional: admin_cidrs, routing (STATIC|BGP default STATIC), bgp_asn, tunnels (list of { psk })."
  type        = any
}

locals {
  routing = try(var.vpn_config.routing, "STATIC")
  tunnels = try(var.vpn_config.tunnels, [])
}

resource "aws_customer_gateway" "this" {
  bgp_asn    = try(var.vpn_config.bgp_asn, 65000)
  ip_address = var.vpn_config.cpe_public_ip
  type       = "ipsec.1"
  tags       = merge(var.tags, { Name = "${var.prefix}-cgw" })
}

# Attaches straight to the TGW. Static routing: the on-prem routes live in the
# TGW route tables (installed by the tgw module from vpn_on_prem_cidrs).
resource "aws_vpn_connection" "this" {
  customer_gateway_id = aws_customer_gateway.this.id
  transit_gateway_id  = var.transit_gateway_id
  type                = "ipsec.1"
  static_routes_only  = local.routing == "STATIC"

  tunnel1_preshared_key = try(local.tunnels[0].psk, null)
  tunnel2_preshared_key = try(local.tunnels[1].psk, null)

  tags = merge(var.tags, { Name = "${var.prefix}-vpn" })
}

output "vpn_connection_id" { value = aws_vpn_connection.this.id }
output "customer_gateway_id" { value = aws_customer_gateway.this.id }
output "tgw_attachment_id" { value = aws_vpn_connection.this.transit_gateway_attachment_id }
output "tunnel_public_ips" {
  value = [
    aws_vpn_connection.this.tunnel1_address,
    aws_vpn_connection.this.tunnel2_address,
  ]
}
