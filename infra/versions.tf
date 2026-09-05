terraform {
  required_version = ">= 1.9.0"

  # Backend is intentionally EMPTY: bucket, key and region are supplied at init
  # via -backend-config flags from platform secrets (TF_STATE_BUCKET,
  # PROJECT_NAME). Backend blocks cannot use variables, and hardcoding a key
  # would make every branch share one state file.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.82"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "udap"
    }
  }
}

# Kubernetes provider, authenticated against the cluster this configuration
# creates. Used only for the default StorageClass (see ebs-csi.tf) — every
# other Kubernetes object is owned by ArgoCD, which must remain the single
# writer of application state.
#
# The exec block gets a fresh token per apply rather than baking a short-lived
# one into state. Referencing the cluster's own attributes means terraform
# orders this correctly without an explicit depends_on.
provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      aws_eks_cluster.main.name,
      "--region",
      var.region,
    ]
  }
}
