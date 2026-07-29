locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  use_panorama = var.management_mode == "panorama"
  use_scm      = var.management_mode == "scm"

  mgmt_access_strategy = var.mgmt_access_strategy
  use_ssm              = local.mgmt_access_strategy == "ssm"
  use_bastion_vm       = local.mgmt_access_strategy == "bastion_vm"
  use_ipsec_vpn        = local.mgmt_access_strategy == "ipsec_vpn"

  vpn_config_raw = (
    local.use_ipsec_vpn && var.vpn_config_path != ""
    ? yamldecode(file(pathexpand(var.vpn_config_path)))
    : null
  )

  vpn_on_prem_cidrs = local.use_ipsec_vpn ? try(local.vpn_config_raw.on_prem_cidrs, []) : []
  vpn_admin_cidrs   = local.use_ipsec_vpn ? try(local.vpn_config_raw.admin_cidrs, local.vpn_on_prem_cidrs) : []

  # Hub subnet tiers striped across two AZs: fw1 lands in the -a subnets (AZ 0),
  # fw2 in the -b subnets (AZ 1), and so on (i % 2). Index map (cidrsubnet /24
  # slices of the hub /16): 1/4 mgmt, 2/5 data (FW dataplane + GWLB nodes),
  # 3/6 trust (TGW attachment), 7 bastion, 8/9 gwlbe (GWLB endpoints),
  # 10/11 egress (per-AZ NAT GW, public).
  hub_subnets = {
    mgmt_a   = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 1), az_index = 0 }
    data_a   = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 2), az_index = 0 }
    trust_a  = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 3), az_index = 0 }
    mgmt_b   = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 4), az_index = 1 }
    data_b   = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 5), az_index = 1 }
    trust_b  = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 6), az_index = 1 }
    gwlbe_a  = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 8), az_index = 0 }
    gwlbe_b  = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 9), az_index = 1 }
    egress_a = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 10), az_index = 0 }
    egress_b = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 11), az_index = 1 }
  }

  # Public jump-host subnet, only materialized by the bastion_vm strategy.
  bastion_subnet_cidr = cidrsubnet(var.hub_vpc_cidr, 8, 7)

  mgmt_subnet_cidrs = [
    local.hub_subnets.mgmt_a.cidr,
    local.hub_subnets.mgmt_b.cidr,
  ]

  mgmt_ingress_cidrs = (
    local.use_ssm ? local.mgmt_subnet_cidrs :
    local.use_bastion_vm ? concat(local.mgmt_subnet_cidrs, [local.bastion_subnet_cidr]) :
    local.use_ipsec_vpn ? local.vpn_admin_cidrs :
    []
  )

  panorama_mgmt_ip = cidrhost(local.hub_subnets.mgmt_a.cidr, 10)

  fws = {
    for i in range(var.fw_count) : format("fw%d", i + 1) => {
      az_suffix = i % 2 == 0 ? "a" : "b"
      hostname  = format("pan-fw%d", i + 1)
      mgmt_ip   = cidrhost(local.hub_subnets[i % 2 == 0 ? "mgmt_a" : "mgmt_b"].cidr, 11 + i)
      data_ip   = cidrhost(local.hub_subnets[i % 2 == 0 ? "data_a" : "data_b"].cidr, 11 + i)
    }
  }

  spoke_cidrs = [for k, v in var.protected_vpcs : v.cidr]
}
