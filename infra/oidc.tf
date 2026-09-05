# ---------------------------------------------------------------------------
# GitHub Actions -> AWS via OIDC.
#
# STATUS: PROVISIONED BUT NOT CURRENTLY USED.
#
# This was the intended authentication path for the delivery pipeline, and it
# is kept intact so it can be switched on without redesign. It is not in use
# because OIDC requires `permissions: id-token: write` on the workflow job, and
# the platform's pipeline spec (.udap/pipeline.yaml) has no `permissions` key —
# write_pipeline refuses it:
#
#   unknown key 'permissions' — allowed: [approval, env, id, kind, needs,
#   outputs, steps, timeout_minutes]
#
# Workflow files are RENDERED from that spec, so the permission cannot be added
# by editing .github/workflows/ either. Without the permission GitHub never
# mints an OIDC token and the action fails with:
#
#   It looks like you might be trying to authenticate with OIDC.
#   Did you mean to set the `id-token` permission?
#   Credentials could not be loaded ... Could not load credentials from any
#   providers
#
# The delivery pipeline therefore authenticates to ECR with the platform's
# injected static credentials, which were already present in the job for
# terraform state access.
#
# TO RE-ENABLE once the platform supports job permissions: add
#   permissions: { id-token: write, contents: read }
# to the build_push / app_release stages, then restore the auth step:
#   - uses: aws-actions/configure-aws-credentials@v4
#     with:
#       role-to-assume: ${{ secrets.AWS_CI_ROLE_ARN }}
#       aws-region: us-east-1
#       unset-current-credentials: "true"   # REQUIRED: static keys in the job
#                                           # env otherwise take precedence and
#                                           # OIDC is silently skipped
# Nothing in this file needs to change: the provider, the repo-scoped role and
# the least-privilege ECR policy are already correct.
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
    effect = "Allow"

    # BOTH actions are required.
    #
    # sts:AssumeRoleWithWebIdentity is the exchange itself.
    #
    # sts:TagSession is required because aws-actions/configure-aws-credentials
    # attaches SESSION TAGS (GitHub repository, workflow, actor, ref) to the
    # assumed session for auditability. If the trust policy omits it, STS
    # rejects the call and the job fails with an AccessDenied naming
    # sts:TagSession — which reads like a missing permission on the CALLER,
    # but is actually a missing permission on THIS trust policy. Granting
    # sts:TagSession to the IAM user does nothing; the role must allow it.
    actions = [
      "sts:AssumeRoleWithWebIdentity",
      "sts:TagSession",
    ]

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
  description        = "Assumed by GitHub Actions via OIDC to push images to ECR (provisioned; see file header for why it is not yet in use)"
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
