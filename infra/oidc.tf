# ---------------------------------------------------------------------------
# GitHub Actions -> AWS via OIDC (no long-lived access keys).
#
# GitHub Actions requests a short-lived OIDC token; AWS STS exchanges it for
# temporary credentials, but ONLY if the token's claims match the trust policy
# below. Nothing secret is stored in the repository.
#
# Scope note: the platform's own provision/destroy stages authenticate with
# platform-injected keys (the terraform state backend is platform-managed and
# that cannot be changed). This role covers the per-commit delivery path —
# build, scan, push to ECR — which is the path that runs on every change.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# One OIDC provider per account per issuer. If GitHub OIDC is already
# configured account-wide, import it instead of creating a duplicate:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # IAM still requires this field. AWS validates GitHub's certificate chain
  # against its own trust store, so the value no longer needs rotating.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_ci_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # Audience must be the STS audience the configure-aws-credentials action
    # requests.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # THE critical condition. Pins the role to one repository AND one branch.
    # A wildcard such as "repo:*:*" would let any repository on GitHub assume
    # this role and push images into your registry.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "github_ci" {
  name               = "${var.project_name}-github-ci"
  description        = "Assumed by GitHub Actions via OIDC to push images to ECR"
  assume_role_policy = data.aws_iam_policy_document.github_ci_assume.json

  # Delivery jobs are short; cap the credential lifetime accordingly.
  max_session_duration = 3600
}

# Least privilege: authenticate to ECR, and push ONLY to this project's
# repository. GetAuthorizationToken cannot be resource-scoped (AWS returns an
# account-level token), which is why it is a separate statement.
data "aws_iam_policy_document" "github_ci_ecr" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushPullThisRepositoryOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "github_ci_ecr" {
  name   = "${var.project_name}-github-ci-ecr"
  role   = aws_iam_role.github_ci.id
  policy = data.aws_iam_policy_document.github_ci_ecr.json
}
