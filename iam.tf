locals {
  resource_name_postfix     = var.aws_cluster_name
  account_id                = data.aws_caller_identity.current.account_id
  partition                 = data.aws_partition.current.partition

  instance_profile_role_name = "castai-eks-${local.resource_name_postfix}-node-role"
  castai_role_name           = "castai-eks-${local.resource_name_postfix}-cluster-role"

  # When a custom instance profile ARN is provided, look it up to resolve its role.
  # Otherwise, use the resources created below.
  effective_instance_profile_arn = coalesce(var.custom_instance_profile_arn, try(aws_iam_instance_profile.castai_instance_profile[0].arn, null))
  effective_node_role_arn        = try(data.aws_iam_instance_profile.custom[0].role_arn, aws_iam_role.castai_instance_profile_role[0].arn)
  effective_node_role_name       = try(data.aws_iam_instance_profile.custom[0].role_name, aws_iam_role.castai_instance_profile_role[0].name)
}

data "aws_partition" "current" {}

# Looks up the custom instance profile to resolve its associated IAM role.
data "aws_iam_instance_profile" "custom" {
  count = var.custom_instance_profile_arn != null ? 1 : 0
  name  = element(split("/", var.custom_instance_profile_arn), length(split("/", var.custom_instance_profile_arn)) - 1)
}

################################################################################
# Instance profile — attached to CAST AI-provisioned EC2 nodes
# Skipped when custom_instance_profile_arn is provided.
################################################################################

resource "aws_iam_role" "castai_instance_profile_role" {
  count = var.custom_instance_profile_arn == null ? 1 : 0
  name  = local.instance_profile_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = ""
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = ["sts:AssumeRole"]
    }]
  })
}

resource "aws_iam_instance_profile" "castai_instance_profile" {
  count = var.custom_instance_profile_arn == null ? 1 : 0
  name  = local.instance_profile_role_name
  role  = aws_iam_role.castai_instance_profile_role[0].name
}

resource "aws_iam_role_policy_attachment" "castai_instance_profile_policies" {
  for_each = var.custom_instance_profile_arn == null ? toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ]) : toset([])
  role       = try(aws_iam_role.castai_instance_profile_role[0].name, "")
  policy_arn = each.value
}

################################################################################
# CAST AI assume role — assumed by the CAST AI user ARN
################################################################################

resource "aws_iam_role" "castai_assume_role" {
  name = local.castai_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        AWS = castai_eks_user_arn.castai_user_arn.arn
      }
      Condition = {
        StringEquals = {
          "sts:ExternalId" = castai_eks_clusterid.cluster_id.id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "castai_assume_role_readonly" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ReadOnlyAccess",
    "arn:${local.partition}:iam::aws:policy/IAMReadOnlyAccess",
  ])
  role       = aws_iam_role.castai_assume_role.name
  policy_arn = each.value
}

# Inline policy with PassRole restricted to the specific CAST AI node role.
# PassRoleEC2 and PassRoleEKS both reference the single instance profile role
# instead of the wildcard arn:aws:iam::*:role/* in the default CAST AI policy.
resource "aws_iam_role_policy" "castai_inline_policy" {
  name = "CastEKSRestrictedAccess"
  role = aws_iam_role.castai_assume_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PassRoleEC2"
        Action   = "iam:PassRole"
        Effect   = "Allow"
        Resource = "arn:${local.partition}:iam::${local.account_id}:role/${local.effective_node_role_name}"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid      = "PassRoleEKS"
        Action   = "iam:PassRole"
        Effect   = "Allow"
        Resource = "arn:${local.partition}:iam::${local.account_id}:role/${local.effective_node_role_name}"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "eks.amazonaws.com"
          }
        }
      },
      {
        Sid    = "NonResourcePermissions"
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "ec2:CreateKeyPair",
          "ec2:DeleteKeyPair",
          "ec2:CreateTags",
          "ec2:ImportKeyPair",
        ]
        Resource = "*"
      },
      {
        Sid    = "RunInstancesPermissions"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "arn:${local.partition}:ec2:*:${local.account_id}:network-interface/*",
          "arn:${local.partition}:ec2:*:${local.account_id}:security-group/*",
          "arn:${local.partition}:ec2:*:${local.account_id}:volume/*",
          "arn:${local.partition}:ec2:*:${local.account_id}:key-pair/*",
          "arn:${local.partition}:ec2:*::image/*",
        ]
      },
      {
        Sid      = "RunInstancesTagRestriction"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "arn:${local.partition}:ec2:${var.aws_cluster_region}:${local.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.aws_cluster_name}" = "owned"
          }
        }
      },
      {
        Sid      = "RunInstancesVpcRestriction"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "arn:${local.partition}:ec2:${var.aws_cluster_region}:${local.account_id}:subnet/*"
        Condition = {
          StringEquals = {
            "ec2:Vpc" = "arn:${local.partition}:ec2:${var.aws_cluster_region}:${local.account_id}:vpc/${var.vpc_id}"
          }
        }
      },
      {
        Sid    = "InstanceActionsTagRestriction"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:CreateTags",
        ]
        Resource = "arn:${local.partition}:ec2:${var.aws_cluster_region}:${local.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/kubernetes.io/cluster/${var.aws_cluster_name}" = ["owned", "shared"]
          }
        }
      },
      {
        Sid    = "AutoscalingActionsTagRestriction"
        Effect = "Allow"
        Action = [
          "autoscaling:UpdateAutoScalingGroup",
          "autoscaling:CreateAutoScalingGroup",
          "autoscaling:DeleteAutoScalingGroup",
          "autoscaling:SuspendProcesses",
          "autoscaling:ResumeProcesses",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "arn:${local.partition}:autoscaling:${var.aws_cluster_region}:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/kubernetes.io/cluster/${var.aws_cluster_name}" = ["owned", "shared"]
          }
        }
      },
      {
        Sid    = "EKS"
        Effect = "Allow"
        Action = [
          "eks:Describe*",
          "eks:List*",
          "eks:TagResource",
          "eks:UntagResource",
          "eks:CreateNodegroup",
          "eks:DeleteNodegroup",
        ]
        Resource = [
          "arn:${local.partition}:eks:${var.aws_cluster_region}:${local.account_id}:cluster/${var.aws_cluster_name}",
          "arn:${local.partition}:eks:${var.aws_cluster_region}:${local.account_id}:nodegroup/${var.aws_cluster_name}/*/*",
        ]
      },
      {
        Sid      = "CreateLaunchTemplateWithTag"
        Effect   = "Allow"
        Action   = "ec2:CreateLaunchTemplate"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.aws_cluster_name}" = "owned"
          }
        }
      },
      {
        Sid    = "ManageLaunchTemplatesAndCreateNodeGroupWithLaunchTemplate"
        Effect = "Allow"
        Action = [
          "ec2:DescribeLaunchTemplates",
          "ec2:DeleteLaunchTemplate",
          "ec2:CreateLaunchTemplateVersion",
          "ec2:DescribeLaunchTemplateVersions",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.aws_cluster_name}" = "owned"
          }
        }
      },
      {
        Sid      = "RunInstancesForEKSNodegroups"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "arn:${local.partition}:ec2:*:*:launch-template/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.aws_cluster_name}" = "owned"
          }
        }
      },
    ]
  })
}
