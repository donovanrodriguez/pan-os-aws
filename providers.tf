provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = try(module.eks_workload[0].cluster_endpoint, "")
  cluster_ca_certificate = try(base64decode(module.eks_workload[0].cluster_ca_cert), "")
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", try(module.eks_workload[0].cluster_name, ""),
      "--region", var.region,
    ]
  }
}
