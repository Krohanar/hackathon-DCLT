resource "aws_eks_addon" "metrics_server" {
  cluster_name  = "solidarytech-production"
  addon_name    = "metrics-server"
  addon_version = "v0.9.0-eksbuild.2"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = {
    Project     = "SolidaryTech"
    Environment = "Production"
    CostCenter  = "NGO-Core"
    Owner       = "FIAP"
    ManagedBy   = "Terraform"
  }
}
