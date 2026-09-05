# ---------------------------------------------------------------------------
# IRSA role for the AWS Load Balancer Controller.
#
# The controller watches Ingress resources and creates real ALBs. Without it an
# Ingress object is inert and no traffic reaches the application.
#
# The trust policy binds ONE Kubernetes service account
# (kube-system/aws-load-balancer-controller) to this IAM role via the cluster's
# OIDC provider. No node-level credentials, no static keys.
#
# NOTE ON THE POLICY BELOW: AWS publishes a reference policy for this
# controller (roughly 40 actions, revised over time). The statements here cover
# the elbv2/ec2 describe+mutate surface required to provision internet-facing
# ALBs for Ingress. If you enable advanced features (WAF association, Shield,
# mTLS on target groups), fetch the current upstream policy rather than
# extending this by trial and error:
#   https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
# ---------------------------------------------------------------------------

locals {
  oidc_provider_url = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

data "aws_iam_policy_document" "lbc_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${var.project_name}-lbc"
  description        = "IRSA role for the AWS Load Balancer Controller"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
}

data "aws_iam_policy_document" "lbc" {
  # Read-only discovery of VPC, subnets, security groups and existing LBs.
  statement {
    sid    = "Discovery"
    effect = "Allow"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools",
      "elasticloadbalancing:Describe*",
      "iam:ListServerCertificates",
      "iam:GetServerCertificate",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "cognito-idp:DescribeUserPoolClient",
      "wafv2:GetWebACL",
      "wafv2:GetWebACLForResource",
      "shield:GetSubscriptionState",
      "shield:DescribeProtection",
    ]
    resources = ["*"]
  }

  # Manage the security groups that front the load balancers.
  statement {
    sid    = "ManageSecurityGroups"
    effect = "Allow"
    actions = [
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = ["*"]
  }

  # Create and manage the ALBs, listeners, rules and target groups.
  statement {
    sid    = "ManageLoadBalancers"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
      # Target registration is how Argo Rollouts shifts canary traffic at the
      # load-balancer level.
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
    ]
    resources = ["*"]
  }

  # The controller creates its own service-linked role on first use.
  statement {
    sid       = "ServiceLinkedRole"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "lbc" {
  name   = "${var.project_name}-lbc"
  role   = aws_iam_role.lbc.id
  policy = data.aws_iam_policy_document.lbc.json
}
