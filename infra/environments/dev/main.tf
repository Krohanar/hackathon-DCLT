locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    CostCenter  = var.cost_center
    ManagedBy   = "Terraform"
    Owner       = "FIAP"
  }

  ecr_repositories = [
    "solidarytech/ngo-service",
    "solidarytech/donation-service",
    "solidarytech/volunteer-service"
  ]
}

module "ecr" {
  source = "../../modules/ecr"

  repositories = local.ecr_repositories
  tags         = local.common_tags
}
