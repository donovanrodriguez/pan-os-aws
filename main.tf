resource "aws_key_pair" "admin" {
  key_name   = "${var.resource_prefix}-admin"
  public_key = local.ssh_public_key
  tags       = var.tags
}

# Most recent VM-Series image for the configured Marketplace product code.
# vm_series_ami_id overrides the lookup when version pinning is required.
data "aws_ami" "vm_series" {
  count       = var.vm_series_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = ["PA-VM-AWS*"]
  }

  filter {
    name   = "product-code"
    values = [var.vm_series_product_code]
  }
}

# Most recent Panorama image for the configured Marketplace product code.
# Only consulted in panorama mode when panorama_ami_id is not pinned.
data "aws_ami" "panorama" {
  count       = local.use_panorama && var.panorama_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = ["Panorama-AWS*"]
  }

  filter {
    name   = "product-code"
    values = [var.panorama_product_code]
  }
}

module "bootstrap_s3" {
  source = "./modules/bootstrap-s3"

  prefix = var.resource_prefix
  tags   = var.tags

  management_mode         = var.management_mode
  panorama_ip             = local.panorama_mgmt_ip
  panorama_auth_key       = var.panorama_vm_auth_key
  panorama_device_group   = var.panorama_device_group
  panorama_template_stack = var.panorama_template_stack
  scm_folder              = var.scm_folder
  scm_pin_id              = var.scm_registration_pin_id
  scm_pin_value           = var.scm_registration_pin_value
  auth_codes              = var.vm_series_auth_codes

  fw_configs = { for k, fw in local.fws : k => { hostname = fw.hostname } }
}

module "tgw" {
  source = "./modules/tgw"

  prefix = var.resource_prefix
  tags   = var.tags

  hub_vpc_id                = module.hub_network.vpc_id
  hub_attachment_subnet_ids = module.hub_network.trust_subnet_ids

  # VPC routes targeting the TGW are created inside the tgw module so they
  # sequence after the corresponding VPC attachment exists (AWS rejects a
  # route to a TGW the VPC is not yet attached to).
  hub_gwlbe_route_table_ids = module.hub_network.gwlbe_route_table_ids
  hub_mgmt_route_table_id   = module.hub_network.mgmt_route_table_id

  spokes = {
    for k, v in var.protected_vpcs : k => {
      vpc_id     = module.protected_spokes[k].vpc_id
      subnet_ids = module.protected_spokes[k].tgw_attachment_subnet_ids
      cidr       = v.cidr
    }
  }

  # Default 0/0 -> TGW for every managed spoke's route table (brownfield
  # spokes keep ownership of their own routing).
  spoke_route_table_ids = {
    for k, v in var.protected_vpcs : k => module.protected_spokes[k].route_table_id if v.create_vpc
  }

  enable_vpn_routing = local.use_ipsec_vpn
  vpn_attachment_id  = local.use_ipsec_vpn ? module.mgmt_access_vpn[0].tgw_attachment_id : null
  vpn_on_prem_cidrs  = local.vpn_on_prem_cidrs
}

module "hub_network" {
  source = "./modules/network-hub"

  prefix = var.resource_prefix
  tags   = var.tags

  vpc_cidr = var.hub_vpc_cidr
  subnets  = local.hub_subnets

  # SCM-managed FWs need outbound internet from the mgmt ENI to reach the SCM
  # service edge; the mgmt subnets are otherwise private. The per-AZ egress
  # NAT gateways always exist for inspected traffic; this only adds the mgmt
  # route to them.
  enable_mgmt_nat_route = local.use_scm

  mgmt_ingress_cidrs = local.mgmt_ingress_cidrs
  mgmt_subnet_cidrs  = local.mgmt_subnet_cidrs
}

module "panorama" {
  count  = local.use_panorama ? 1 : 0
  source = "./modules/panorama"

  prefix = var.resource_prefix
  tags   = var.tags

  ami_id        = coalesce(var.panorama_ami_id, one(data.aws_ami.panorama[*].id))
  instance_type = var.panorama_instance_type
  key_name      = aws_key_pair.admin.key_name
  log_volume_gb = var.panorama_log_volume_gb

  subnet_id         = module.hub_network.subnet_ids["mgmt_a"]
  security_group_id = module.hub_network.panorama_sg_id
  private_ip        = local.panorama_mgmt_ip
}

module "firewalls" {
  source = "./modules/firewall-fleet"

  prefix = var.resource_prefix
  tags   = var.tags

  ami_id        = coalesce(var.vm_series_ami_id, one(data.aws_ami.vm_series[*].id))
  instance_type = var.vm_series_instance_type
  key_name      = aws_key_pair.admin.key_name

  fws = {
    for k, fw in local.fws : k => {
      hostname       = fw.hostname
      mgmt_subnet_id = module.hub_network.subnet_ids["mgmt_${fw.az_suffix}"]
      data_subnet_id = module.hub_network.subnet_ids["data_${fw.az_suffix}"]
      mgmt_ip        = fw.mgmt_ip
      data_ip        = fw.data_ip
    }
  }

  mgmt_sg_id = module.hub_network.fw_mgmt_sg_id
  data_sg_id = module.hub_network.fw_data_sg_id

  bootstrap_bucket_name = module.bootstrap_s3.bucket_name
  bootstrap_bucket_arn  = module.bootstrap_s3.bucket_arn
}

module "gwlb" {
  source = "./modules/gwlb"

  prefix = var.resource_prefix
  tags   = var.tags

  vpc_id          = module.hub_network.vpc_id
  data_subnet_ids = module.hub_network.data_subnet_ids
  gwlbe_subnets   = module.hub_network.gwlbe_subnet_ids

  fw_data_ips = module.firewalls.fw_data_ips

  # Routes targeting the GWLB endpoints live in the gwlb module so they
  # sequence after the endpoints exist.
  trust_route_table_ids  = module.hub_network.trust_route_table_ids
  egress_route_table_ids = module.hub_network.egress_route_table_ids
  spoke_cidrs            = local.spoke_cidrs
}

module "protected_spokes" {
  for_each = var.protected_vpcs
  source   = "./modules/network-spoke-generic"

  name            = "spoke-${each.key}"
  vpc_cidr        = each.value.cidr
  subnets         = each.value.subnets
  create_vpc      = each.value.create_vpc
  existing_vpc_id = each.value.existing_vpc_id
  tags            = merge(var.tags, { spoke = each.key })
}

module "nginx_mysql_workload" {
  count  = var.enable_nginx_mysql_workload ? 1 : 0
  source = "./modules/workload-nginx-mysql"

  prefix = var.resource_prefix
  tags   = var.tags

  vpc_id        = module.protected_spokes[var.nginx_mysql_target_vpc].vpc_id
  web_subnet_id = module.protected_spokes[var.nginx_mysql_target_vpc].subnet_ids["web"]
  db_subnet_ids = [
    module.protected_spokes[var.nginx_mysql_target_vpc].subnet_ids["db-a"],
    module.protected_spokes[var.nginx_mysql_target_vpc].subnet_ids["db-b"],
  ]
  web_subnet_cidr = var.protected_vpcs[var.nginx_mysql_target_vpc].subnets["web"].cidr

  instance_type = var.workload_instance_type
  key_name      = aws_key_pair.admin.key_name

  mysql_admin_username = var.mysql_admin_username
  mysql_admin_password = var.mysql_admin_password
  mysql_instance_class = var.mysql_instance_class
  mysql_storage_gb     = var.mysql_storage_gb
}

module "eks_workload" {
  count  = var.enable_eks_workload ? 1 : 0
  source = "./modules/workload-eks"

  prefix = var.resource_prefix
  tags   = var.tags

  cluster_name = "${var.resource_prefix}-eks"
  vpc_id       = module.protected_spokes[var.eks_target_vpc].vpc_id
  subnet_ids = [
    module.protected_spokes[var.eks_target_vpc].subnet_ids["nodes-a"],
    module.protected_spokes[var.eks_target_vpc].subnet_ids["nodes-b"],
  ]

  kubernetes_version     = var.eks_kubernetes_version
  node_count             = var.eks_node_count
  node_instance_type     = var.eks_node_instance_type
  deploy_sample_workload = var.eks_deploy_sample_workload
}

module "mgmt_access_ssm" {
  count  = local.use_ssm ? 1 : 0
  source = "./modules/mgmt-access-ssm"

  prefix = var.resource_prefix
  tags   = var.tags
  region = var.region

  vpc_id     = module.hub_network.vpc_id
  vpc_cidr   = var.hub_vpc_cidr
  subnet_ids = module.hub_network.mgmt_subnet_ids
}

module "mgmt_access_bastion_vm" {
  count  = local.use_bastion_vm ? 1 : 0
  source = "./modules/mgmt-access-bastion-vm"

  prefix = var.resource_prefix
  tags   = var.tags

  vpc_id              = module.hub_network.vpc_id
  internet_gateway_id = module.hub_network.internet_gateway_id
  subnet_cidr         = local.bastion_subnet_cidr
  instance_type       = var.bastion_instance_type
  key_name            = aws_key_pair.admin.key_name
  admin_source_cidrs  = var.admin_source_cidrs
}

module "mgmt_access_vpn" {
  count  = local.use_ipsec_vpn ? 1 : 0
  source = "./modules/mgmt-access-vpn"

  prefix = var.resource_prefix
  tags   = var.tags

  transit_gateway_id = module.tgw.tgw_id
  vpn_config         = local.vpn_config_raw
}
