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
