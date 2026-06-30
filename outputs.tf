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
  description = "Arn of created cast instance role"
  value       = aws_iam_role.castai_instance_profile_role.arn
}

output "instance_profile_arn" {
  description = "Arn of created cast instance profile"
  value       = aws_iam_instance_profile.castai_instance_profile.arn
}

output "cast_role_arn" {
  description = "Arn of created cast role"
  value       = aws_iam_role.castai_assume_role.arn
}
