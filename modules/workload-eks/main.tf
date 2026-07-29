terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

variable "prefix" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
variable "cluster_name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" {
  description = "nodes-a + nodes-b subnet IDs (EKS requires subnets in at least two AZs)."
  type        = list(string)
}
variable "kubernetes_version" { type = string }
variable "node_count" { type = number }
variable "node_instance_type" { type = string }
variable "deploy_sample_workload" {
  description = "Apply k8s nginx Deployment + internal NLB Service after the cluster comes up. Requires the kubernetes provider to reach the private API endpoint (tunnel/VPN/in-VPC runner)."
  type        = bool
  default     = false
}

# --- IAM ---------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.prefix}-eks-cluster-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name = "${var.prefix}-eks-node-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# --- Cluster -----------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version
  tags     = var.tags

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.prefix}-eks-np-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.node_instance_type]
  tags            = var.tags

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_ecr,
    aws_iam_role_policy_attachment.node_cni,
  ]
}

# --- Optional sample workload (private endpoint: needs a tunnel) -------------

resource "kubernetes_namespace_v1" "demo" {
  count = var.deploy_sample_workload ? 1 : 0
  metadata {
    name = "demo"
  }
  depends_on = [aws_eks_node_group.default]
}

resource "kubernetes_deployment_v1" "nginx" {
  count = var.deploy_sample_workload ? 1 : 0
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.demo[0].metadata[0].name
    labels = {
      app = "nginx"
    }
  }

  spec {
    replicas = 2
    selector {
      match_labels = { app = "nginx" }
    }
    template {
      metadata {
        labels = { app = "nginx" }
      }
      spec {
        container {
          image = "nginxinc/nginx-unprivileged:stable"
          name  = "nginx"
          port {
            container_port = 8080
          }
        }
      }
    }
  }
  depends_on = [aws_eks_node_group.default]
}

resource "kubernetes_service_v1" "nginx" {
  count = var.deploy_sample_workload ? 1 : 0
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.demo[0].metadata[0].name
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-internal" = "true"
    }
  }
  spec {
    type = "LoadBalancer"
    selector = {
      app = "nginx"
    }
    port {
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
  }
  depends_on = [aws_eks_node_group.default]
}

output "cluster_name" { value = aws_eks_cluster.this.name }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "cluster_ca_cert" {
  value     = aws_eks_cluster.this.certificate_authority[0].data
  sensitive = true
}
