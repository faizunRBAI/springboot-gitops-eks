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
