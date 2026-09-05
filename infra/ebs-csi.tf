# ---------------------------------------------------------------------------
# EBS CSI driver.
#
# WHY THIS IS REQUIRED, not optional:
# Kubernetes removed the in-tree AWS EBS provisioner in 1.23. Without this
# addon an EKS cluster has NO working storage class, so any PersistentVolume
# Claim stays unbound forever and its pod never schedules:
#
#   Warning  FailedScheduling  0/2 nodes are available: pod has unbound
#   immediate PersistentVolumeClaims.
#
# Prometheus requests a 10Gi PVC (gitops/values/monitoring-values.yaml), so
# without the driver the whole monitoring stack stalls — and with it the
# canary analysis that Argo Rollouts depends on.
#
# The alternative, an emptyDir volume, would schedule immediately but discard
# all metrics whenever the pod restarts. Canary analysis that silently loses
# its history is worse than no canary analysis, so durable storage wins.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_assume" {
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
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.project_name}-ebs-csi"
  description        = "IRSA role for the EBS CSI driver controller"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

# AWS maintains this managed policy for exactly this driver; it is the
# documented attachment and tracks the driver's evolving requirements.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.ebs_csi,
  ]

  tags = {
    Name = "${var.project_name}-ebs-csi"
  }
}

# A default StorageClass is required as well: the addon installs the driver but
# does NOT mark any class default, and a PVC without storageClassName binds
# only to the default. gp3 is cheaper and faster than gp2 for this workload.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  # WaitForFirstConsumer places the volume in the same AZ as the pod that
  # claims it. Immediate binding can create the volume in an AZ with no
  # schedulable node, which reproduces the very Pending state this fixes.
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}
