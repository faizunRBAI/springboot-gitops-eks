# Outputs consumed by later pipeline stages.
#
# IMPORTANT: the configure and verify stages read these by re-running
# `terraform init` + `terraform output -raw <name>` themselves. They are NOT
# threaded through GitHub job outputs, because these values embed
# PROJECT_NAME (a repository secret) and GitHub silently DROPS any job output
# containing a secret substring — producing an empty string and a confusing
# failure several stages later.

output "cluster_name" {
  description = "EKS cluster name; used by `aws eks update-kubeconfig`."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = aws_eks_cluster.main.version
}

output "ecr_repository_url" {
  description = "ECR repository URL that CI pushes images to."
  value       = aws_ecr_repository.app.repository_url
}

output "ci_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC. Set this as the AWS_CI_ROLE_ARN repository secret after the first apply."
  value       = aws_iam_role.github_ci.arn
}

output "lbc_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller service account."
  value       = aws_iam_role.lbc.arn
}

output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet ids hosting the worker nodes."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet ids hosting the ALB and NAT gateway."
  value       = aws_subnet.public[*].id
}

output "region" {
  description = "AWS region of the deployment."
  value       = var.region
}
