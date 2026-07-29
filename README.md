# pan-os-aws

Terraform for a Palo Alto Networks VM-Series firewall fleet behind an AWS Gateway Load Balancer (GWLB), fronting a Transit Gateway hub-and-spoke topology in `us-east-1`. This follows the PAN best-practice centralized inspection architecture: the security VPC holds an N-instance firewall fleet (AZ-striped a/b) targeted by a GWLB over GENEVE, every spoke's default route lands on the TGW, and the TGW's spoke route table forwards everything into the hub where per-AZ GWLB endpoints steer it through the firewalls. Spoke-to-spoke traffic hairpins through the fleet; internet egress is centralized behind per-AZ NAT gateways.

```
                                     Internet
                                        ^
                                        |
+=======================================|========================================+
|                    HUB (SECURITY) VPC | 10.10.0.0/16  (us-east-1)              |
|                                +------+------+                                 |
|                                |     IGW     |                                 |
|                                +--+-------+--+                                 |
|                                   |       |                                    |
|  +--------------------------------+--+ +--+--------------------------------+   |
|  | EGRESS-A 10.10.10.0/24 (AZ a)     | | EGRESS-B 10.10.11.0/24 (AZ b)     |   |
|  |   NAT GW a                        | |   NAT GW b                        |   |
|  |   rt: 0/0 -> IGW                  | |   rt: 0/0 -> IGW                  |   |
|  |       spokes -> GWLBe-a           | |       spokes -> GWLBe-b           |   |
|  +--------------------------------+--+ +--+--------------------------------+   |
|                                   |       |                                    |
|  +--------------------------------+--+ +--+--------------------------------+   |
|  | GWLBE-A 10.10.8.0/24 (AZ a)       | | GWLBE-B 10.10.9.0/24 (AZ b)       |   |
|  |   GWLB endpoint a                 | |   GWLB endpoint b                 |   |
|  |   rt: 0/0 -> NAT GW a             | |   rt: 0/0 -> NAT GW b             |   |
|  |       spokes -> TGW               | |       spokes -> TGW               |   |
|  +---------------+-------------------+ +-------------------+---------------+   |
|                  |         GENEVE (UDP 6081)               |                   |
|  +---------------v-------------------+ +-------------------v---------------+   |
|  | DATA-A 10.10.2.0/24 (AZ a)        | | DATA-B 10.10.5.0/24 (AZ b)        |   |
|  |   GWLB node a                     | |   GWLB node b                     |   |
|  |   FW1 data ENI .11 (idx 1,       <---> FW2 data ENI .12 (idx 1,        |   |
|  |   src/dst check off)              | |   src/dst check off)              |   |
|  |                                   | |                                   |   |
|  |   VM-Series fleet, fw_count       | |   AZ-striped: fw1/fw3 -> a,       |   |
|  |   instances, m5.xlarge BYOL       | |   fw2/fw4 -> b, ...               |   |
|  +-----------------------------------+ +-----------------------------------+   |
|                                                                                |
|  +-----------------------------------+ +-----------------------------------+   |
|  | TRUST-A 10.10.3.0/24 (AZ a)       | | TRUST-B 10.10.6.0/24 (AZ b)       |   |
|  |   [TGW attachment ENI]            | |   [TGW attachment ENI]            |   |
|  |   rt: 0/0 -> GWLBe-a              | |   rt: 0/0 -> GWLBe-b              |   |
|  +---------------+-------------------+ +-------------------+---------------+   |
|                  |                                         |                   |
|  +---------------+-----------------------------------------+---------------+   |
|  | MGMT-A 10.10.1.0/24 (AZ a)          MGMT-B 10.10.4.0/24 (AZ b)          |   |
|  |   Panorama .10 (panorama mode)      FW2 mgmt ENI .12                    |   |
|  |   FW1 mgmt ENI .11                                                      |   |
|  |   [SSM interface endpoints here when mgmt_access_strategy = ssm]        |   |
|  |   rt: 0/0 -> NAT GW a (scm mode only)                                   |   |
|  +------------------------------------+------------------------------------+   |
|                                       |                                        |
+=======================================|========================================+
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
  ->  traffic flow / route target

DATA-PATH SUMMARY
  S->N egress  : spoke -> RT 0/0 -> TGW spoke-rt -> hub attachment (trust
                 subnets, appliance mode) -> trust rt 0/0 -> AZ-local GWLBe ->
                 GWLB -> firewall data ENI (GENEVE) -> inspected -> back via
                 GWLBe -> gwlbe rt 0/0 -> AZ NAT GW -> egress rt 0/0 -> IGW
  N->S return  : IGW -> NAT GW (de-NAT) -> egress rt spoke CIDR -> AZ-local
                 GWLBe -> same firewall (GWLB flow stickiness) -> gwlbe rt
                 spoke CIDR -> TGW hub-rt -> spoke
  E->W         : spoke-app -> TGW spoke-rt -> hub -> trust rt -> GWLBe -> FW
                 inspection -> gwlbe rt spoke CIDR -> TGW hub-rt -> spoke-eks
                 (no direct spoke-to-spoke path)
  N->S ingress : this design centralizes egress + east-west. Inbound to spoke
                 apps is served today via the return path above (NAT'd flows
                 only). Unsolicited inbound would use the distributed-GWLBe
                 pattern: per-spoke endpoints consuming
                 gwlb_endpoint_service_name plus IGW edge routes in the spoke.
                 Documented as a future option, not built here.
  Mgmt path    : operator -> {SSM endpoints | bastion subnet | VPN attachment}
                 -> FW/Panorama mgmt ENIs in the hub mgmt subnets. No mgmt
                 plane on the internet.
  Health/scale : GWLB target group health-checks each firewall's data ENI
                 (TCP/443). Unhealthy targets stop receiving new flows; add
                 capacity by raising fw_count. No failover scripting.
```

## Why GWLB instead of an HA pair

The previous revision of this project ran a classic active/passive VM-Series HA pair: an EIP anchored on fw1's untrust ENI, and the PAN-OS AWS HA plugin moving secondary IPs, the EIP, and rewriting route tables on failover via IAM permissions. The GWLB architecture replaces all of that:

- **Scale-out, not failover.** The GWLB spreads flows across `fw_count` independent firewalls. Capacity is added by launching more instances, not by resizing a pair.
- **No failover scripting.** GWLB health checks (TCP/443 against each data ENI) remove unhealthy targets automatically. The HA plugin, its IAM failover policy (`ec2:AssociateAddress`, `ec2:ReplaceRoute`, ...), and the failover-time route rewrites are gone; the firewall instance role now only reads the bootstrap bucket.
- **Flow symmetry without route tricks.** GENEVE encapsulation preserves the original packet end-to-end, and GWLB flow stickiness (5-tuple hash) pins both directions of a flow to the same firewall, so stateful inspection works with N active devices.
- **AZ symmetry via appliance mode.** The TGW hub attachment keeps `appliance_mode_support = enable`, so both directions of a cross-AZ flow enter the hub in the same AZ and hit the same AZ-local GWLBe/firewall path.
- **Reusable inspection service.** The GWLB is exposed as a VPC endpoint service (`gwlb_endpoint_service_name`), so future distributed-ingress endpoints in spoke VPCs can consume the same fleet.

## What this builds

| Layer | Resource | Notes |
|---|---|---|
| Hub VPC | `10.10.0.0/16`, IGW, 10 subnets (mgmt/data/trust/gwlbe/egress x AZ a/b), per-AZ NAT GWs in egress | trust rt 0/0 -> GWLBe; gwlbe rt 0/0 -> NAT + spokes -> TGW; egress rt 0/0 -> IGW + spokes -> GWLBe |
| Firewalls | `fw_count` VM-Series fleet (default 2, min 1), AZ-striped a/b, 2 ENIs each (mgmt idx 0, data idx 1 with src/dst check off) | static host IPs `.11+N` per tier; IAM role `pan-hub-spoke-fw-*` grants S3 bootstrap read only |
| GWLB | Gateway LB in the data subnets, GENEVE target group (port 6081, IP targets = FW data ENIs, TCP/443 health checks), endpoint service, per-AZ GWLBe in dedicated subnets | cross-zone LB enabled so one AZ's endpoint survives the other AZ's fleet loss |
| Transit | TGW with default association/propagation disabled, hub attachment in trust subnets with appliance mode, per-spoke attachments, hub-rt + spoke-rt | all spoke egress and east-west transits the firewall fleet |
| Bootstrap | Private S3 bucket `pan-hub-spoke-fw-bootstrap-<rand>`, per-FW prefixes `fw1/`, `fw2/` with `config/`, `license/`, `software/`, `content/` | `init-cfg.txt` rendered per `management_mode`; includes `plugin-op-commands=aws-gwlb-inspect:enable` |
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
| `cidr` | yes | - | Used for TGW hub-rt routes plus the hub gwlbe/egress return routes. Must match the existing VPC's CIDR when `create_vpc = false`. |
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
| `scm` | No Panorama VM. Mgmt route table gets a default route to the AZ-a NAT gateway for egress to the SCM service edge | `init-cfg.txt` sets `panorama-server=cloud`, `dgname=<scm_folder>`, and the device certificate `vm-series-auto-registration-pin-id/value` |

SCM mode prereqs:

1. SCM tenant with Strata Cloud Manager activated and the target folder created (Workflows > NGFW Setup > Folder Management). `scm_folder` must match its name exactly.
2. Device certificate registration PIN generated in the Customer Support Portal (Assets > Device Certificates). Set `scm_registration_pin_id` / `scm_registration_pin_value`. PINs expire; regenerate if the apply is delayed past the PIN lifetime.
3. Outbound internet from the FW mgmt ENI. This module handles it with the mgmt NAT route; the egress source IP is exported as `mgmt_nat_public_ip`.

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

Then in the Panorama UI: create device group `DG-AWS-USE1` and template stack `TS-AWS-USE1` (must match `variables.tf`), configure the dataplane interface, zone, and an interface management profile permitting HTTPS on ethernet1/1 (required for GWLB health checks), then push to the firewalls.

### SCM mode: single-shot

```bash
# in terraform.tfvars:
#   management_mode            = "scm"
#   scm_folder                 = "<SCM folder name>"
#   scm_registration_pin_id    = "<PIN ID>"
#   scm_registration_pin_value = "<PIN value>"
terraform apply
# FWs boot, install the device cert via the registration PIN, and register
# into the SCM folder. Push config from SCM once they show up, including the
# ethernet1/1 interface config + mgmt profile for GWLB health checks.
```

### Strategy A: `ssm` (default)

Interface endpoints for SSM Session Manager in the hub mgmt subnets. No public IPs on the mgmt plane and no extra compute.

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
- **`mgmt-interface-swap` is intentionally absent** from the bootstrap. PAN documents the swap as needed only when the GWLB target type is `instance` (traffic hits the first ENI). This design registers each firewall's dataplane ENI IP as an `ip` target, where PAN states the swap is not required, so mgmt stays on device index 0 and the dataplane on index 1.
- **GWLB health checks need firewall-side config.** The target group probes TCP/443 against each data ENI (PAN docs: HTTP is refused by the VM-Series; HTTPS or TCP are the options). Targets stay unhealthy until you push an ethernet1/1 config with an interface management profile permitting HTTPS. Until then the GWLBe drops traffic; verify target health in the EC2 console after the first policy push.
- **SSM strategy** deploys the endpoints, not an agent: PAN-OS/Panorama images do not run the SSM agent (see Strategy A caveats).
- **Panorama licensing egress** (panorama mode): the mgmt route table has no internet route by default (the NAT route only lands in SCM mode). For `request license fetch` to reach `updates.paloaltonetworks.com`, either temporarily enable the mgmt NAT route, license via the VPN path, or use the Panorama UI's offline activation. Review before first boot.
- **Appliance mode** is enabled on the hub TGW attachment so both directions of a flow use the same AZ (and thus the same AZ-local GWLBe). Do not disable it; asymmetric flows would bypass the AZ-local inspection path. GWLB flow stickiness then pins the flow to one firewall.
- **Cross-zone load balancing** is enabled on the GWLB so a single-firewall fleet (or a full-AZ outage) does not blackhole the other AZ's endpoint, at the cost of some cross-AZ data charges. Disable in `modules/gwlb` if you run >= 1 healthy firewall per AZ and want strict AZ containment.
- **Jumbo frames** stay enabled (`op-command-modes=jumbo-frame`); GENEVE adds encapsulation overhead, so keep MTU headroom consistent across the path if you change this.
- **Brownfield spokes** (`create_vpc = false`): TF attaches the VPC and installs hub-side routes only. You must point the existing VPC's route tables at the TGW yourself, and the VPC needs at least one subnet per AZ you want attached.
- **BYOL auth codes** land in the bootstrap bucket. The bucket is private with public access blocked, but rotate/remove the codes after bootstrap completes if your compliance posture requires it.
- **Do not commit** `terraform.tfvars` or state files; both carry secrets (auth keys, PINs, DB password). The `.gitignore` already covers them.
