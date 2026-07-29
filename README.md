# pan-os-aws

Terraform for a Palo Alto Networks VM-Series HA pair fronting a Transit Gateway hub-and-spoke AWS topology in `us-east-1`. The security VPC holds the firewall pair (AZ-striped a/b), every spoke's default route lands on the TGW, and the TGW's spoke route table forwards everything into the hub for inspection. Spoke-to-spoke traffic hairpins through the firewalls.

```
                                       Internet
                                          |
                                          v
+================================================================================+
|                    HUB (SECURITY) VPC  10.10.0.0/16  (us-east-1)               |
|                                                                                |
|   +-----------------+                              +----------------------+    |
|   |  IGW            |                              |  NAT GW (scm mode)   |    |
|   |  (north/south)  |                              |  mgmt egress to SCM  |    |
|   +--------+--------+                              +-----------+----------+    |
|            |                                                   |               |
|   +--------v-------------------------------+  +----------------v---------+    |
|   |  UNTRUST-A  10.10.2.0/24  (AZ a)       |  |  UNTRUST-B  10.10.5.0/24 |    |
|   |  FW1 untrust ENI .11  <-- EIP          |  |  FW2 untrust ENI .12     |    |
|   |  (source/dest check off)               |  |  (source/dest check off) |    |
|   +--------+-------------------------------+  +----------------+---------+    |
|            |                                                   |               |
|   +--------v-------------------+              +----------------v---------+    |
|   |  VM-Series FW1  (AZ a)     |              |  VM-Series FW2  (AZ b)   |    |
|   |  m5.xlarge, BYOL           |              |  m5.xlarge, BYOL         |    |
|   |  mgmt .11 / trust .11      |              |  mgmt .12 / trust .12    |    |
|   +--------+-------------------+              +----------------+---------+    |
|            |                                                   |               |
|   +--------v-------------------------------+  +----------------v---------+    |
|   |  TRUST-A  10.10.3.0/24  (AZ a)         |  |  TRUST-B  10.10.6.0/24   |    |
|   |  FW1 trust ENI .11                     |  |  FW2 trust ENI .12       |    |
|   |  [TGW attachment ENI lives here]       |  |  [TGW attachment ENI]    |    |
|   +--------+-------------------------------+  +----------------+---------+    |
|            |                                                   |               |
|   +--------+---------------------------------------------------+---------+    |
|   |  MGMT-A  10.10.1.0/24 (AZ a)          MGMT-B  10.10.4.0/24 (AZ b)    |    |
|   |  Panorama .10 (panorama mode)         FW2 mgmt ENI .12               |    |
|   |  FW1 mgmt ENI .11                                                    |    |
|   |  [SSM interface endpoints here when mgmt_access_strategy = ssm]      |    |
|   +----------------------------------+-----------------------------------+    |
|                                      |                                        |
+======================================|=========================================+
                                       |
                              +--------v--------+
                              |  TRANSIT GW     |
                              |  +-----------+  |
                              |  | hub-rt    |  |  <-- spoke CIDRs -> spoke attachments
                              |  +-----------+  |      on-prem CIDRs -> VPN attachment
                              |  | spoke-rt  |  |  <-- 0.0.0.0/0 -> hub attachment
                              |  +-----------+  |      (appliance mode on hub attach)
                              +--+-----------+--+
                                 |           |
                     +-----------+           +-----------+
                     v                                   v
+==========================+          +================================
|  SPOKE-APP VPC           |          |  SPOKE-EKS VPC                 |
|  10.20.0.0/16            |          |  10.30.0.0/16                  |
|                          |          |                                |
| +----------------------+ |          | +----------------------------+ |
| | web 10.20.1.0/24 (a) | |          | | nodes-a 10.30.1.0/24 (AZ a)| |
| | +------------------+ | |          | | nodes-b 10.30.2.0/24 (AZ b)| |
| | | nginx VM Ubuntu  | | |          | |                            | |
| | | t3.small         | | |          | |  EKS private cluster       | |
| | +--------+---------+ | |          | |  endpoint_private only     | |
| +----------|-----------+ |          | |  2x m5.large workers       | |
|            | 3306        |          | |  (AIRS AI GW Hybrid host)  | |
| +----------v-----------+ |          | +----------------------------+ |
| | db-a 10.20.2.0/24 (a)| |          |  RT: 0.0.0.0/0 -> TGW          |
| | db-b 10.20.3.0/24 (b)| |          +================================+
| |  RDS MySQL 8.0       | |
| |  db.t3.medium, 50 GB | |
| +----------------------+ |
|  RT: 0.0.0.0/0 -> TGW    |
+==========================+

LEGEND
  ==  VPC boundary
  --  subnet boundary
  ->  traffic flow

DATA-PATH SUMMARY
  N->S ingress : Internet -> EIP on FW1 untrust ENI -> PAN sec policy ->
                 FW trust ENI -> trust RT (spoke CIDR -> TGW) -> hub-rt -> spoke
  S->N egress  : spoke -> RT 0/0 -> TGW spoke-rt -> hub attachment (trust
                 subnets, appliance mode) -> active FW -> SNAT untrust -> IGW
  E->W         : spoke-app -> TGW spoke-rt -> hub -> FW inspection -> trust RT
                 -> TGW hub-rt -> spoke-eks   (no direct spoke-to-spoke path)
  Mgmt path    : operator -> {SSM endpoints | bastion subnet | VPN attachment}
                 -> FW/Panorama mgmt ENIs in the hub mgmt subnets. No mgmt
                 plane on the internet.
  HA           : plugin-driven failover; the surviving FW re-associates the
                 untrust EIP / secondary IPs and rewrites routes via the
                 instance-profile IAM permissions (${prefix}-fw-ha-*).
```

## What this builds

| Layer | Resource | Notes |
|---|---|---|
| Hub VPC | `10.10.0.0/16`, IGW, 6 subnets (mgmt/untrust/trust x AZ a/b), NAT GW on mgmt (SCM mode only) | untrust RT 0/0 -> IGW; trust RT spoke CIDRs -> TGW |
| Firewalls | `fw_count` VM-Series (default 2), AZ-striped a/b, 3 ENIs each (mgmt idx 0, untrust idx 1, trust idx 2), EIP on fw1 untrust | static host IPs `.11+N` per tier; IAM role `pan-hub-spoke-fw-ha-*` for S3 bootstrap read + HA failover API calls |
| Transit | TGW with default association/propagation disabled, hub attachment in trust subnets with appliance mode, per-spoke attachments, hub-rt + spoke-rt | all spoke egress and east-west transits the firewalls |
| Bootstrap | Private S3 bucket `pan-hub-spoke-fw-bootstrap-<rand>`, per-FW prefixes `fw1/`, `fw2/` with `config/`, `license/`, `software/`, `content/` | `init-cfg.txt` rendered per `management_mode` |
| Panorama | Single instance in mgmt-a (`10.10.1.10`), m5.2xlarge, 2 TB gp3 log volume (`management_mode = panorama` only) | required AMI ID variable |
| Spoke-app | nginx Ubuntu VM (web) + RDS MySQL 8.0 across db-a/db-b; toggle `enable_nginx_mysql_workload` (default on) | SG allows 3306 only from the web subnet |
| Spoke-eks | Private EKS cluster (`endpoint_private_access` only) + managed node group across nodes-a/nodes-b; toggle `enable_eks_workload` (default on) | doubles as the Prisma AIRS AI Gateway Hybrid data plane, see below |
| Mgmt access | one of: SSM interface endpoints, public jump host, or TGW site-to-site VPN | `mgmt_access_strategy` |

## Protected VPCs

Spokes are declared as a map (`var.protected_vpcs`). The TGW attaches each one and installs the routes so every spoke's default path goes through the firewalls. Add, remove, or rename spokes by editing the map; no module wiring changes.

```hcl
protected_vpcs = {
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
  finance = {
    cidr    = "10.40.0.0/16"
    subnets = { app = { cidr = "10.40.1.0/24", az_index = 0 } }
  }
  # Attach an existing VPC you already own (brownfield). TF only adds the TGW
  # attachment (discovering one subnet per AZ) and the hub-side routes; you keep
  # ownership of that VPC's subnets and route tables, including pointing its
  # default route at the TGW yourself.
  legacy = {
    cidr            = "10.50.0.0/16"
    create_vpc      = false
    existing_vpc_id = "vpc-0123456789abcdef0"
  }
}
```

Per-entry fields:

| Field | Required | Default | Notes |
|---|---|---|---|
| `cidr` | yes | - | Used for TGW hub-rt + hub trust RT route entries. Must match the existing VPC's CIDR when `create_vpc = false`. |
| `subnets` | optional | `{}` | Map of subnet name -> `{ cidr, az_index }`. Only used when `create_vpc = true`. Workload modules reference subnets by name. |
| `create_vpc` | optional | `true` | `false` skips VPC/subnet creation; only adds the TGW attachment. |
| `existing_vpc_id` | when `create_vpc = false` | - | ID of the existing VPC. It must already contain at least one subnet. |
| `description` | optional | `""` | Tag for traceability. |

Workload modules:

- `enable_nginx_mysql_workload` (default true) puts nginx + RDS MySQL into `nginx_mysql_target_vpc`. That entry must define subnets `web`, `db-a`, and `db-b` (the two db subnets in different AZs for the RDS subnet group).
- `enable_eks_workload` (default true) puts the EKS cluster into `eks_target_vpc`. That entry must define subnets `nodes-a` and `nodes-b` in different AZs.
- Validation `check` blocks reject mismatched target keys or missing subnet names before plan completes.
- Workload modules can only deploy into managed VPCs (`create_vpc = true`). For `create_vpc = false` entries, layer your own workload TF on top.

## Management plane: Panorama vs Strata Cloud Manager

`management_mode` picks how the firewalls are managed:

| Mode | What deploys | Bootstrap |
|---|---|---|
| `panorama` (default) | Panorama VM at `10.10.1.10` in the hub mgmt-a subnet | `init-cfg.txt` points at the Panorama private IP with `vm-auth-key`, `dgname`, `tplname` |
| `scm` | No Panorama VM. NAT Gateway added for mgmt subnet egress to the SCM service edge | `init-cfg.txt` sets `panorama-server=cloud`, `dgname=<scm_folder>`, and the device certificate `vm-series-auto-registration-pin-id/value` |

SCM mode prereqs:

1. SCM tenant with Strata Cloud Manager activated and the target folder created (Workflows > NGFW Setup > Folder Management). `scm_folder` must match its name exactly.
2. Device certificate registration PIN generated in the Customer Support Portal (Assets > Device Certificates). Set `scm_registration_pin_id` / `scm_registration_pin_value`. PINs expire; regenerate if the apply is delayed past the PIN lifetime.
3. Outbound internet from the FW mgmt ENI. This module handles it with the mgmt NAT Gateway; the egress source IP is exported as `mgmt_nat_public_ip`.

In SCM mode `panorama_vm_auth_key`, `panorama_device_group`, and `panorama_template_stack` are ignored. Firewalls appear in SCM under the folder after first boot + device cert install (allow ~10-15 min).

## Connecting to mgmt

FW + Panorama mgmt ENIs are **private** in every strategy. Pick how operators reach them with `mgmt_access_strategy`:

| Strategy | Deploys | Reach mgmt via |
|---|---|---|
| `ssm` (default) | SSM/ssmmessages/ec2messages interface endpoints in the hub mgmt subnets | `aws ssm start-session ... --document-name AWS-StartPortForwardingSession` (see caveat below) |
| `bastion_vm` | Ubuntu jump host with public IP in a dedicated hub subnet (`10.10.7.0/24`), SG-gated SSH from `admin_source_cidrs` | `ssh -J ubuntu@<bastion_public_ip> admin@<fw-private-ip>` |
| `ipsec_vpn` | Customer gateway + site-to-site VPN attached to the TGW (config in YAML) | Bring up your CPE against `vpn_tunnel_public_ips`, SSH/HTTPS to mgmt private IPs over the tunnel |

After apply, `terraform output connect_hint` prints the exact command for the active strategy. For `ipsec_vpn`, point `vpn_config_path` at a YAML file matching `examples/vpn-config.example.yaml`.

## Prereqs

1. AWS account + credentials configured (`aws configure` / SSO). Terraform >= 1.6.
2. Marketplace subscriptions accepted once per account for both BYOL listings:
   - Palo Alto Networks VM-Series Next-Generation Firewall (BYOL)
   - Palo Alto Networks Panorama (BYOL)
   Accept them in the AWS Marketplace console, then copy the AMI ID for your region into `vm_series_ami_id` / `panorama_ami_id`. The Marketplace listing page shows the AMI ID per region under "Launch new instance"; alternatively use `aws ec2 describe-images --owners aws-marketplace --filters "Name=name,Values=*<listing name fragment>*"` and pick the BYOL image for your target PAN-OS version. This project does not hardcode product codes; verify the AMI against the listing you subscribed to.
3. PAN-OS BYOL auth codes from your CSP/CSSP portal (`vm_series_auth_codes`). Panorama needs its own BYOL auth code (separate SKU) for first-boot licensing.
4. `management_mode = panorama`: Panorama VM auth key. Chicken-and-egg: apply Panorama first, generate the key on it, then full apply (walkthrough below).
5. `management_mode = scm`: SCM tenant + folder + device cert registration PIN. No phased apply needed.
6. SSH keypair at `ssh_public_key_path` (default `~/.ssh/id_rsa.pub`); it is uploaded as an EC2 key pair.

## Usage

Common to all strategies:

```bash
cp terraform.tfvars.example terraform.tfvars
# fill in AMI IDs, auth codes, MySQL password
# pick mgmt_access_strategy + lock down admin CIDRs
terraform init
```

### Panorama mode (default): two-phase apply

The Panorama VM auth key is a chicken-and-egg dependency: Panorama must exist to mint the key, but firewalls need the key in their bootstrap.

```bash
# Phase 1: stand up the hub network, Panorama, and the chosen mgmt-access module
terraform apply \
  -target=module.hub_network \
  -target=module.panorama \
  -target=module.mgmt_access_ssm       # or _bastion_vm / _vpn per strategy

# Reach Panorama via the chosen strategy (connect_hint), then on the CLI:
#   request license fetch auth-code <PANORAMA_AUTH_CODE>
#   show system info | match serial          # verify serial populated
#   commit
#   request bootstrap vm-auth-key generate lifetime 24
# Paste the key into terraform.tfvars (panorama_vm_auth_key)

# Phase 2: everything
terraform apply
```

Then in the Panorama UI: create device group `DG-AWS-USE1` and template stack `TS-AWS-USE1` (must match `variables.tf`), configure HA via template, push to firewalls.

### SCM mode: single-shot

```bash
# in terraform.tfvars:
#   management_mode            = "scm"
#   scm_folder                 = "<SCM folder name>"
#   scm_registration_pin_id    = "<PIN ID>"
#   scm_registration_pin_value = "<PIN value>"
terraform apply
# FWs boot, install the device cert via the registration PIN, and register
# into the SCM folder. Push config from SCM once they show up.
```

### Strategy A: `ssm` (default)

Interface endpoints for SSM Session Manager in the hub mgmt subnets. No public IPs anywhere and no extra compute.

**tfvars:**
```hcl
mgmt_access_strategy = "ssm"
```

**Steps:**
```bash
terraform apply -target=module.hub_network -target=module.panorama -target=module.mgmt_access_ssm

PANO_ID=$(terraform output -raw panorama_instance_id)

# Port-forward localhost:8443 -> panorama:443 (web UI)
aws ssm start-session \
  --target "$PANO_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters 'portNumber=443,localPortNumber=8443'
# browse https://localhost:8443
```

**Caveats:**
- SSM sessions require the **SSM agent running on the target instance** with an instance profile that allows SSM. PAN-OS and Panorama images do not ship an SSM agent, so direct sessions against them will not work out of the box. Practical patterns: run a tiny SSM-managed Linux instance in a mgmt subnet and use `AWS-StartPortForwardingSessionToRemoteHost` toward the Panorama/FW private IPs, or pick `bastion_vm` / `ipsec_vpn` for direct reachability. The endpoints deployed here are the plumbing either way.
- Session Manager needs the `session-manager-plugin` installed next to the AWS CLI on your workstation.

### Strategy B: `bastion_vm`

Self-managed Ubuntu jump host in a dedicated public hub subnet.

**tfvars:**
```hcl
mgmt_access_strategy  = "bastion_vm"
admin_source_cidrs    = ["203.0.113.42/32"]   # SG ingress for SSH 22
bastion_instance_type = "t3.micro"
```

**Steps:**
```bash
terraform apply -target=module.hub_network -target=module.panorama -target=module.mgmt_access_bastion_vm

BASTION=$(terraform output -raw bastion_public_ip)
PANO=$(terraform output -raw panorama_private_ip)

# SSH to Panorama via ProxyJump
ssh -J ubuntu@$BASTION admin@$PANO

# Or port-forward Panorama HTTPS for the browser UI:
ssh -L 8443:$PANO:443 ubuntu@$BASTION
# browse https://localhost:8443

# After Panorama setup + vm-auth-key:
terraform apply

# SSH to firewalls via the same bastion:
ssh -J ubuntu@$BASTION admin@<fw mgmt ip from: terraform output fw_mgmt_ips>
```

**Caveats:**
- The validation `check` rejects `admin_source_cidrs = ["0.0.0.0/0"]` for this strategy. Set a specific CIDR.
- You own bastion patching. First login: `sudo apt-get update && sudo apt-get -y upgrade`.

### Strategy C: `ipsec_vpn`

TGW site-to-site VPN from an existing on-prem CPE. No public IPs on mgmt; operators reach mgmt over the tunnel.

**tfvars:**
```hcl
mgmt_access_strategy = "ipsec_vpn"
vpn_config_path      = "./vpn-config.yaml"
```

**vpn-config.yaml** (copy `examples/vpn-config.example.yaml`):
```yaml
cpe_public_ip: "198.51.100.10"
on_prem_cidrs:
  - "192.168.0.0/16"
admin_cidrs:                       # subset allowed to reach FW/Panorama mgmt
  - "192.168.50.0/24"
routing: "STATIC"                  # or BGP
bgp_asn: 65000
tunnels:
  - psk: "tunnel-1-psk"            # omit to let AWS auto-generate
  - psk: "tunnel-2-psk"
```

**Steps:**
```bash
# 1. Stand up TGW + hub + Panorama + VPN (no firewalls yet)
terraform apply \
  -target=module.hub_network \
  -target=module.tgw \
  -target=module.panorama \
  -target=module.mgmt_access_vpn

# 2. Grab the AWS side of the tunnels
terraform output vpn_tunnel_public_ips

# 3. If you didn't set PSKs in YAML, fetch the auto-generated ones:
aws ec2 describe-vpn-connections \
  --vpn-connection-ids $(terraform output -raw vpn_connection_id) \
  --query 'VpnConnections[0].Options.TunnelOptions[].PreSharedKey'

# 4. Configure your on-prem CPE:
#    - Peer 1: <tunnel 1 public IP> with PSK 1
#    - Peer 2: <tunnel 2 public IP> with PSK 2
#    - Encryption domain: on_prem_cidrs <-> 10.10.0.0/16 (hub VPC)
#    - AWS also renders a vendor config: aws ec2 get-vpn-connection-device-sample-configuration

# 5. Verify tunnels UP:
aws ec2 describe-vpn-connections \
  --vpn-connection-ids $(terraform output -raw vpn_connection_id) \
  --query 'VpnConnections[0].VgwTelemetry[].Status'

# 6. From a host inside admin_cidrs, reach Panorama directly:
ssh admin@10.10.1.10        # or browse https://10.10.1.10

# 7. After Panorama setup + vm-auth-key:
terraform apply
```

**Caveats:**
- Mgmt SGs only permit ingress from `admin_cidrs` (defaults to `on_prem_cidrs`). Confirm operator subnets are covered.
- For BGP routing set `routing: "BGP"` plus your `bgp_asn`; on-prem routes then come from BGP instead of the static TGW routes.

## EKS spoke as the Prisma AIRS AI Gateway Hybrid data plane

The `eks` spoke is intentionally shaped to host the **Prisma AIRS AI Gateway Hybrid** data plane:

- **Multi-AZ nodes**: the managed node group spans `nodes-a`/`nodes-b`, matching the gateway's availability expectations.
- **All worker egress flows through the PAN firewall**: the spoke's only default route is the TGW, so every image pull and control-plane call is inspected in the hub.
- **Firewall policy must allow** the workers to reach `registry.portkey.ai` plus the container registries the charts pull from (e.g. `mcr.microsoft.com`, `quay.io`, `ghcr.io`, Docker Hub) and the SCM service edge for gateway registration. Until those rules exist, node bootstrap and `helm install` will hang on pulls.
- The `helm install` of the AI Gateway data plane happens per the AIGW deployment guide, from a host that can reach the private EKS endpoint (`terraform output eks_update_kubeconfig_command`).
- `eks_deploy_sample_workload = false` by default because the API endpoint is private; the kubernetes provider on your laptop cannot reach it without a tunnel/VPN or an in-VPC runner.

## Cleanup

```bash
terraform destroy
```

Notes:

- RDS: `skip_final_snapshot = true` and `deletion_protection = false` are set for lab teardown. If you flipped either for production data, unset them and re-apply before destroy.
- EKS clusters take ~10 min to delete; internal NLBs created by the sample Service must be gone first (destroy handles it when the sample workload was applied via TF).

## Caveats + things to verify before prod

- **AMI IDs are inputs on purpose.** Marketplace AMI IDs differ per region and PAN-OS version, so this project requires `vm_series_ami_id` / `panorama_ami_id` instead of guessing product codes. Make sure the AMI is the **BYOL** flavor; PAYG changes the licensing model and the bootstrap auth codes won't apply.
- **Instance sizes**: `m5.xlarge` (VM-Series) and `m5.2xlarge` (Panorama) are common defaults; consult the PAN-OS supported instance list for your target version before resizing.
- **`op-command-modes=mgmt-interface-swap`** swaps eth0/eth1 roles on AWS so the dataplane owns the first ENI. Verify the resulting interface mapping against the ENI ordering here (mgmt idx 0, untrust idx 1, trust idx 2) for your PAN-OS version, and adjust the ordering or drop the swap if your design expects otherwise.
- **SSM strategy** deploys the endpoints, not an agent: PAN-OS/Panorama images do not run the SSM agent (see Strategy A caveats).
- **Panorama licensing egress** (panorama mode): the mgmt subnets have no internet route by default (the NAT GW only deploys in SCM mode). For `request license fetch` to reach `updates.paloaltonetworks.com`, either temporarily set `enable_mgmt_nat_gateway` logic to your needs, license via the VPN path, or use the Panorama UI's offline activation. Review before first boot.
- **HA failover** relies on the PAN-OS AWS plugin using the `${prefix}-fw-ha-*` instance profile to move secondary IPs, the untrust EIP, and rewrite routes. Configure HA (via Panorama template or manually) after bootstrap; Terraform only lays the IAM + network groundwork.
- **Appliance mode** is enabled on the hub TGW attachment so both directions of a flow use the same AZ (and thus the same firewall). Do not disable it; asymmetric flows would be dropped by the stateful inspection.
- **Brownfield spokes** (`create_vpc = false`): TF attaches the VPC and installs hub-side routes only. You must point the existing VPC's route tables at the TGW yourself, and the VPC needs at least one subnet per AZ you want attached.
- **BYOL auth codes** land in the bootstrap bucket. The bucket is private with public access blocked, but rotate/remove the codes after bootstrap completes if your compliance posture requires it.
- **Do not commit** `terraform.tfvars` or state files; both carry secrets (auth keys, PINs, DB password). The `.gitignore` already covers them.
