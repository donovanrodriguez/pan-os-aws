check "mgmt_access_vpn_config_present" {
  assert {
    condition = (
      !local.use_ipsec_vpn ||
      (var.vpn_config_path != "" && local.vpn_config_raw != null)
    )
    error_message = "mgmt_access_strategy = ipsec_vpn requires var.vpn_config_path pointing to a readable YAML file."
  }
}

check "mgmt_access_vpn_config_fields" {
  assert {
    condition = (
      !local.use_ipsec_vpn ||
      local.vpn_config_raw == null
      ? true
      : alltrue([
        try(local.vpn_config_raw.cpe_public_ip, null) != null,
        length(try(local.vpn_config_raw.on_prem_cidrs, [])) > 0,
      ])
    )
    error_message = "VPN YAML must define cpe_public_ip and a non-empty on_prem_cidrs list."
  }
}

check "mgmt_access_admin_cidrs_locked_down" {
  assert {
    condition = (
      !local.use_bastion_vm ||
      !contains(var.admin_source_cidrs, "0.0.0.0/0")
    )
    error_message = "admin_source_cidrs = 0.0.0.0/0 with mgmt_access_strategy = bastion_vm exposes SSH to the internet. Restrict the list before applying."
  }
}

check "panorama_auth_key_required" {
  assert {
    condition     = !local.use_panorama || var.panorama_vm_auth_key != null
    error_message = "management_mode = panorama requires panorama_vm_auth_key (generate on Panorama: 'request bootstrap vm-auth-key generate lifetime <hours>')."
  }
}

check "scm_settings_required" {
  assert {
    condition = !local.use_scm || alltrue([
      var.scm_folder != null,
      var.scm_registration_pin_id != null,
      var.scm_registration_pin_value != null,
    ])
    error_message = "management_mode = scm requires scm_folder, scm_registration_pin_id, and scm_registration_pin_value (PIN from CSP > Assets > Device Certificates)."
  }
}

check "mysql_password_required_for_workload" {
  assert {
    condition = (
      !var.enable_nginx_mysql_workload ||
      var.mysql_admin_password != null
    )
    error_message = "enable_nginx_mysql_workload = true requires mysql_admin_password (tfvars or TF_VAR_mysql_admin_password)."
  }
}

check "fw_count_redundancy" {
  assert {
    condition     = var.fw_count >= 2
    error_message = "fw_count = 1 deploys with no firewall redundancy: GWLB health checks detect failure but there is no healthy target to fail over to. Fine for labs; use >= 2 elsewhere."
  }
}

check "nginx_mysql_target_vpc_exists" {
  assert {
    condition = (
      !var.enable_nginx_mysql_workload ||
      contains(keys(var.protected_vpcs), var.nginx_mysql_target_vpc)
    )
    error_message = "nginx_mysql_target_vpc must reference a key in protected_vpcs."
  }
}

check "nginx_mysql_target_subnets_exist" {
  assert {
    condition = (
      !var.enable_nginx_mysql_workload ||
      !contains(keys(var.protected_vpcs), var.nginx_mysql_target_vpc) ||
      alltrue([
        contains(keys(var.protected_vpcs[var.nginx_mysql_target_vpc].subnets), "web"),
        contains(keys(var.protected_vpcs[var.nginx_mysql_target_vpc].subnets), "db-a"),
        contains(keys(var.protected_vpcs[var.nginx_mysql_target_vpc].subnets), "db-b"),
      ])
    )
    error_message = "protected_vpcs[nginx_mysql_target_vpc].subnets must define 'web', 'db-a', and 'db-b' (db-a/db-b in different AZs for the RDS subnet group)."
  }
}

check "eks_target_vpc_exists" {
  assert {
    condition = (
      !var.enable_eks_workload ||
      contains(keys(var.protected_vpcs), var.eks_target_vpc)
    )
    error_message = "eks_target_vpc must reference a key in protected_vpcs."
  }
}

check "eks_target_subnets_exist" {
  assert {
    condition = (
      !var.enable_eks_workload ||
      !contains(keys(var.protected_vpcs), var.eks_target_vpc) ||
      alltrue([
        contains(keys(var.protected_vpcs[var.eks_target_vpc].subnets), "nodes-a"),
        contains(keys(var.protected_vpcs[var.eks_target_vpc].subnets), "nodes-b"),
      ])
    )
    error_message = "protected_vpcs[eks_target_vpc].subnets must define 'nodes-a' and 'nodes-b' (different AZs; EKS requires subnets in at least two AZs)."
  }
}

check "workload_target_vpcs_are_managed" {
  assert {
    condition = (
      (!var.enable_nginx_mysql_workload || try(var.protected_vpcs[var.nginx_mysql_target_vpc].create_vpc, true)) &&
      (!var.enable_eks_workload || try(var.protected_vpcs[var.eks_target_vpc].create_vpc, true))
    )
    error_message = "Workload modules can only deploy into VPCs where create_vpc = true (TF needs to create the subnets they reference). For create_vpc = false, layer your own workload TF on top."
  }
}
