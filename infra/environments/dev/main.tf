locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    CostCenter  = var.cost_center
    ManagedBy   = "Terraform"
    Owner       = "FIAP"
  }

  environment_slug = lower(var.environment)
  eks_cluster_name = "solidarytech-${lower(var.environment)}"

  ecr_repositories = [
    "solidarytech/ngo-service",
    "solidarytech/donation-service",
    "solidarytech/volunteer-service"
  ]
}

module "network" {
  source = "../../modules/network"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = local.common_tags
}

module "ecr" {
  source = "../../modules/ecr"

  repositories = local.ecr_repositories
  tags         = local.common_tags
}

module "sqs_donations" {
  source = "../../modules/sqs"

  queue_name = "solidary-donations"
  tags       = local.common_tags
}

module "dynamodb_volunteers" {
  source = "../../modules/dynamodb"

  table_name = "SolidaryTechVolunteers"
  tags       = local.common_tags
}

module "rds_postgres" {
  source = "../../modules/rds"

  project_name        = var.project_name
  environment         = var.environment
  vpc_id              = module.network.vpc_id
  private_subnet_ids  = module.network.private_subnet_ids
  allowed_cidr_blocks = [var.vpc_cidr]

  db_name         = "ngo_db"
  master_username = "solidaryadmin"

  tags = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name        = local.eks_cluster_name
  cluster_version     = var.eks_cluster_version
  public_subnet_ids   = module.network.public_subnet_ids
  node_instance_types = var.eks_node_instance_types
  node_desired_size   = var.eks_node_desired_size
  node_min_size       = var.eks_node_min_size
  node_max_size       = var.eks_node_max_size

  tags = local.common_tags
}
