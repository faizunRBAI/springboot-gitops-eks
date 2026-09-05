resource "aws_ecr_repository" "app" {
  name = var.project_name

  # Tags stay mutable so a rebuild of the same SHA can overwrite; the delivery
  # path always deploys an explicit SHA tag, never :latest.
  image_tag_mutability = "MUTABLE"

  # Second scanning layer: Trivy gates the image in CI before the push, and ECR
  # rescans on push so CVEs disclosed AFTER the build are still surfaced.
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-ecr"
  }
}

# Keep storage bounded: SHA-tagged images accumulate one per commit forever.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain the 30 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
