output "cluster_id" {
  value       = castai_eks_clusterid.cluster_id.id
  description = "CAST AI cluster ID"
}

output "cluster_token" {
  value       = castai_eks_cluster.my_castai_cluster.cluster_token
  description = "CAST AI cluster token used by Castware to authenticate to Mothership"
  sensitive   = true
}

output "instance_profile_role_arn" {
  description = "ARN of the IAM role attached to the CAST AI instance profile (created or custom)"
  value       = local.effective_node_role_arn
}

output "instance_profile_arn" {
  description = "ARN of the IAM instance profile used for CAST AI nodes (created or custom)"
  value       = local.effective_instance_profile_arn
}

output "cast_role_arn" {
  description = "Arn of created cast role"
  value       = aws_iam_role.castai_assume_role.arn
}
