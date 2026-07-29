variable "region" {
  description = "Primary AWS region for the deployment."
  type        = string
  default     = "us-east-1"
}

variable "resource_prefix" {
  description = "Prefix applied to all created resources."
  type        = string
  default     = "pan-hub-spoke"
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default = {
    project = "pan-hub-spoke"
    managed = "terraform"
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key used for EC2 instances (key pair uploaded once, referenced everywhere)."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "hub_vpc_cidr" {
  description = "CIDR for the hub (security) VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "protected_vpcs" {
  description = <<-EOT
    Map of VPCs to attach behind the firewall hub via the Transit Gateway. Key = short name (also used as target_vpc ref).

    For each entry:
      cidr            : VPC CIDR. Required even when attaching an existing VPC (used for TGW hub-rt + hub trust routes).
      subnets         : map of subnet name -> { cidr, az_index }. az_index picks from the region's available AZs.
                        Workload modules expect specific names (nginx_mysql: "web" + "db-a" + "db-b"; EKS: "nodes-a" + "nodes-b").
      create_vpc      : true creates a new VPC + subnets here. false attaches an existing VPC by ID (the existing VPC
                        must already contain at least one subnet; you keep ownership of its subnets and route tables).
      existing_vpc_id : required when create_vpc = false.
      description     : optional, tag for traceability.
  EOT
  type = map(object({
    cidr            = string
    subnets         = optional(map(object({ cidr = string, az_index = number })), {})
    create_vpc      = optional(bool, true)
    existing_vpc_id = optional(string)
    description     = optional(string, "")
  }))
  default = {
    app = {
      cidr = "10.20.0.0/16"
      subnets = {
        web  = { cidr = "10.20.1.0/24", az_index = 0 }
        db-a = { cidr = "10.20.2.0/24", az_index = 0 }
        db-b = { cidr = "10.20.3.0/24", az_index = 1 }
      }
    }
    eks = {
      cidr = "10.30.0.0/16"
      subnets = {
        nodes-a = { cidr = "10.30.1.0/24", az_index = 0 }
        nodes-b = { cidr = "10.30.2.0/24", az_index = 1 }
      }
    }
  }
  validation {
    condition = alltrue([
      for k, v in var.protected_vpcs :
      v.create_vpc || v.existing_vpc_id != null
    ])
    error_message = "Each protected_vpcs entry with create_vpc = false must set existing_vpc_id."
  }
}

variable "admin_source_cidrs" {
  description = "CIDRs allowed to SSH into the bastion jump host (mgmt_access_strategy = bastion_vm). Ignored for ssm and ipsec_vpn strategies."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "mgmt_access_strategy" {
  description = "How operators reach the FW/Panorama mgmt interfaces. One of: ssm, bastion_vm, ipsec_vpn."
  type        = string
  default     = "ssm"
  validation {
    condition     = contains(["ssm", "bastion_vm", "ipsec_vpn"], var.mgmt_access_strategy)
    error_message = "mgmt_access_strategy must be one of: ssm, bastion_vm, ipsec_vpn."
  }
}

variable "bastion_instance_type" {
  description = "Instance type for the jump host (mgmt_access_strategy = bastion_vm)."
  type        = string
  default     = "t3.micro"
}

variable "vpn_config_path" {
  description = "Path to a YAML file describing the site-to-site VPN (mgmt_access_strategy = ipsec_vpn). See examples/vpn-config.example.yaml for schema."
  type        = string
  default     = ""
}

variable "fw_count" {
  description = "Number of VM-Series firewalls in the GWLB fleet. Instances are AZ-striped a/b with static host IPs .11+N in each hub subnet tier. GWLB health checks handle failover, so 1 is a valid (non-redundant) minimum."
  type        = number
  default     = 2
  validation {
    condition     = var.fw_count >= 1 && var.fw_count <= 8
    error_message = "fw_count must be between 1 and 8."
  }
}

variable "vm_series_ami_id" {
  description = "AMI ID of the VM-Series BYOL Marketplace image in var.region. See README > Prereqs for how to find it."
  type        = string
}

# Consult the PAN-OS supported instance list for your PAN-OS version before changing.
variable "vm_series_instance_type" {
  description = "EC2 instance type for VM-Series firewalls."
  type        = string
  default     = "m5.xlarge"
}

variable "panorama_ami_id" {
  description = "AMI ID of the Panorama BYOL Marketplace image in var.region. Required even in scm mode (unused there). See README > Prereqs."
  type        = string
}

# Consult the Panorama setup prerequisites in the PAN docs before downsizing.
variable "panorama_instance_type" {
  description = "EC2 instance type for Panorama."
  type        = string
  default     = "m5.2xlarge"
}

variable "panorama_log_volume_gb" {
  description = "Size of the extra Panorama log EBS volume in GB."
  type        = number
  default     = 2048
}

variable "management_mode" {
  description = "Firewall management plane. 'panorama' deploys a Panorama VM in the hub mgmt subnet and bootstraps FWs against it. 'scm' skips Panorama entirely and bootstraps FWs to Strata Cloud Manager (panorama-server=cloud); requires scm_folder + device certificate registration PIN, and adds a NAT Gateway for FW mgmt egress to the SCM service edge."
  type        = string
  default     = "panorama"
  validation {
    condition     = contains(["panorama", "scm"], var.management_mode)
    error_message = "management_mode must be one of: panorama, scm."
  }
}

variable "scm_folder" {
  description = "Strata Cloud Manager folder the firewalls register into (init-cfg dgname). Create it in SCM (Workflows > NGFW Setup > Folder Management) before applying. Required when management_mode = scm."
  type        = string
  default     = null
}

variable "scm_registration_pin_id" {
  description = "Device certificate auto-registration PIN ID generated in the Customer Support Portal (Assets > Device Certificates). Required when management_mode = scm."
  type        = string
  sensitive   = true
  default     = null
}

variable "scm_registration_pin_value" {
  description = "Device certificate auto-registration PIN value paired with scm_registration_pin_id. Required when management_mode = scm."
  type        = string
  sensitive   = true
  default     = null
}

variable "panorama_vm_auth_key" {
  description = "Panorama VM auth key used by FW bootstrap. Generate on Panorama after first boot: 'request bootstrap vm-auth-key generate lifetime <hours>'. Required when management_mode = panorama."
  type        = string
  sensitive   = true
  default     = null
}

variable "panorama_device_group" {
  description = "Panorama device-group name the firewalls will register into."
  type        = string
  default     = "DG-AWS-USE1"
}

variable "panorama_template_stack" {
  description = "Panorama template stack the firewalls will register into."
  type        = string
  default     = "TS-AWS-USE1"
}

variable "vm_series_auth_codes" {
  description = "List of PAN-OS BYOL auth codes uploaded to /license/authcodes in the bootstrap bucket."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "enable_nginx_mysql_workload" {
  description = "Deploy the example nginx + RDS MySQL workload into a protected VPC."
  type        = bool
  default     = true
}

variable "nginx_mysql_target_vpc" {
  description = "Key in protected_vpcs where the nginx + MySQL workload lands. The VPC's subnets map must contain 'web', 'db-a', and 'db-b'."
  type        = string
  default     = "app"
}

variable "workload_instance_type" {
  description = "EC2 instance type for the sample nginx workload."
  type        = string
  default     = "t3.small"
}

variable "mysql_admin_username" {
  description = "RDS MySQL admin user."
  type        = string
  default     = "panadmin"
}

variable "mysql_admin_password" {
  description = "RDS MySQL admin password. Required when enable_nginx_mysql_workload = true. Provide via TF_VAR_mysql_admin_password or tfvars; do not commit."
  type        = string
  sensitive   = true
  default     = null
}

variable "mysql_instance_class" {
  description = "RDS instance class for the MySQL database."
  type        = string
  default     = "db.t3.medium"
}

variable "mysql_storage_gb" {
  description = "RDS MySQL allocated storage size (GB)."
  type        = number
  default     = 50
}

variable "enable_eks_workload" {
  description = "Deploy the example private EKS cluster into a protected VPC. Doubles as the Prisma AIRS AI Gateway Hybrid data plane host (see README)."
  type        = bool
  default     = true
}

variable "eks_target_vpc" {
  description = "Key in protected_vpcs where the EKS cluster lands. The VPC's subnets map must contain 'nodes-a' and 'nodes-b'."
  type        = string
  default     = "eks"
}

# Check the currently supported EKS versions before bumping:
# aws eks describe-cluster-versions --query 'clusterVersions[].clusterVersion'
variable "eks_kubernetes_version" {
  description = "Kubernetes version for EKS."
  type        = string
  default     = "1.31"
}

variable "eks_node_count" {
  description = "Number of EKS worker nodes (spread across nodes-a/nodes-b)."
  type        = number
  default     = 2
}

variable "eks_node_instance_type" {
  description = "Instance type for EKS worker nodes."
  type        = string
  default     = "m5.large"
}

variable "eks_deploy_sample_workload" {
  description = "Deploy sample nginx Deployment + internal NLB Service into EKS. Requires the TF host to reach the private API endpoint (SSM tunnel, bastion, VPN, or in-VPC runner)."
  type        = bool
  default     = false
}
