output "management_mode" {
  description = "Firewall management plane in use: panorama VM or Strata Cloud Manager."
  value       = var.management_mode
}

output "mgmt_access_strategy" {
  description = "Active mgmt access strategy."
  value       = local.mgmt_access_strategy
}

output "panorama_private_ip" {
  description = "Private mgmt IP of Panorama. Reach it via the chosen mgmt_access_strategy. Null in SCM mode."
  value       = try(module.panorama[0].private_ip, null)
}

output "panorama_instance_id" {
  description = "Panorama EC2 instance ID (used by SSM session commands). Null in SCM mode."
  value       = try(module.panorama[0].instance_id, null)
}

output "fw_mgmt_ips" {
  description = "Private mgmt IPs per firewall. Reach via the chosen mgmt access strategy."
  value       = module.firewalls.fw_mgmt_ips
}

output "fw_instance_ids" {
  value = module.firewalls.fw_instance_ids
}

output "fw1_untrust_eip" {
  description = "Elastic IP on fw1's untrust ENI (public ingress/egress anchor)."
  value       = module.firewalls.fw1_untrust_eip
}

output "tgw_id" {
  description = "Transit Gateway ID."
  value       = module.tgw.tgw_id
}

output "mgmt_nat_public_ip" {
  description = "NAT Gateway egress IP for the hub mgmt subnets (SCM mode). FWs reach the SCM service edge from this address."
  value       = module.hub_network.mgmt_nat_public_ip
}

output "bootstrap_bucket_name" {
  value = module.bootstrap_s3.bucket_name
}

output "protected_vpcs" {
  description = "Per-spoke VPC ID + subnet ID map for everything attached behind the firewall."
  value = {
    for k, m in module.protected_spokes : k => {
      vpc_id     = m.vpc_id
      subnet_ids = m.subnet_ids
      is_managed = m.is_managed
    }
  }
}

output "bastion_public_ip" {
  description = "Public IP of the jump-host VM (bastion_vm strategy)."
  value       = local.use_bastion_vm ? module.mgmt_access_bastion_vm[0].bastion_public_ip : null
}

output "vpn_tunnel_public_ips" {
  description = "AWS-side public IPs of the site-to-site VPN tunnels (ipsec_vpn strategy). Configure your CPE against these."
  value       = local.use_ipsec_vpn ? module.mgmt_access_vpn[0].tunnel_public_ips : null
}

output "vpn_connection_id" {
  description = "ID of the VPN connection (ipsec_vpn strategy). Use with 'aws ec2 describe-vpn-connections' to fetch tunnel details + PSKs."
  value       = local.use_ipsec_vpn ? module.mgmt_access_vpn[0].vpn_connection_id : null
}

output "connect_hint" {
  description = "How to reach mgmt interfaces with the chosen strategy."
  value = (
    local.use_ssm ? "aws ssm start-session --target ${try(module.panorama[0].instance_id, "<instance-id>")} --document-name AWS-StartPortForwardingSession --parameters 'portNumber=443,localPortNumber=8443'   # then browse https://localhost:8443 (target must run the SSM agent; see README caveats)" :
    local.use_bastion_vm ? module.mgmt_access_bastion_vm[0].connect_hint :
    local.use_ipsec_vpn ? "Bring up your CPE against vpn_tunnel_public_ips, then SSH/HTTPS to panorama_private_ip / fw_mgmt_ips over the tunnel." :
    "unknown"
  )
}

output "nginx_vm_private_ip" {
  value = try(module.nginx_mysql_workload[0].nginx_private_ip, null)
}

output "mysql_endpoint" {
  value = try(module.nginx_mysql_workload[0].mysql_endpoint, null)
}

output "eks_cluster_name" {
  value = try(module.eks_workload[0].cluster_name, null)
}

output "eks_update_kubeconfig_command" {
  description = "Run to fetch the kubeconfig for the EKS cluster (private endpoint: requires tunnel/VPN/in-VPC runner)."
  value       = var.enable_eks_workload ? "aws eks update-kubeconfig --name ${try(module.eks_workload[0].cluster_name, "")} --region ${var.region}" : null
}
