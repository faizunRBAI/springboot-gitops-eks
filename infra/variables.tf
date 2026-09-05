variable "project_name" {
  type        = string
  description = "Branch-scoped project name; prefixes every cloud resource."
}

variable "region" {
  type        = string
  description = "AWS region for all resources."
  default     = "us-east-1"
}

variable "github_repo" {
  type        = string
  description = "owner/repo of the monorepo. Scopes the GitHub OIDC role trust policy so ONLY this repository can assume it."
}

variable "github_branch" {
  type        = string
  description = "Branch permitted to assume the CI role via OIDC."
  default     = "main"
}

variable "cluster_version" {
  type        = string
  description = "EKS Kubernetes version. Must be in STANDARD support (1.33-1.36 as of 2026-07); extended-support versions cost more."
  default     = "1.33"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC."
  default     = "10.0.0.0/16"
}

variable "node_instance_type" {
  type        = string
  description = "Instance type for the managed node group."
  default     = "t3.medium"
}

variable "node_desired_size" {
  type        = number
  description = "Desired node count."
  default     = 2
}

variable "node_min_size" {
  type        = number
  description = "Minimum node count."
  default     = 2
}

variable "node_max_size" {
  type        = number
  description = "Maximum node count."
  default     = 4
}
