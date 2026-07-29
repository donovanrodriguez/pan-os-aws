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
  # fw2 in the -b subnets (AZ 1), and so on (i % 2).
  hub_subnets = {
    mgmt_a    = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 1), az_index = 0 }
    untrust_a = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 2), az_index = 0 }
    trust_a   = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 3), az_index = 0 }
    mgmt_b    = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 4), az_index = 1 }
    untrust_b = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 5), az_index = 1 }
    trust_b   = { cidr = cidrsubnet(var.hub_vpc_cidr, 8, 6), az_index = 1 }
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
      az_suffix  = i % 2 == 0 ? "a" : "b"
      hostname   = format("pan-fw%d", i + 1)
      mgmt_ip    = cidrhost(local.hub_subnets[i % 2 == 0 ? "mgmt_a" : "mgmt_b"].cidr, 11 + i)
      untrust_ip = cidrhost(local.hub_subnets[i % 2 == 0 ? "untrust_a" : "untrust_b"].cidr, 11 + i)
      trust_ip   = cidrhost(local.hub_subnets[i % 2 == 0 ? "trust_a" : "trust_b"].cidr, 11 + i)
    }
  }
}
