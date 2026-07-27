output "vpc_id" {
  description = "ID da VPC."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas."
  value       = module.network.private_subnet_ids
}

output "ecr_repository_urls" {
  description = "URLs dos repositórios ECR."
  value       = module.ecr.repository_urls
}

output "donations_queue_url" {
  description = "URL da fila SQS de doações."
  value       = module.sqs_donations.queue_url
}

output "donations_queue_arn" {
  description = "ARN da fila SQS de doações."
  value       = module.sqs_donations.queue_arn
}

output "volunteers_table_name" {
  description = "Nome da tabela DynamoDB de voluntários."
  value       = module.dynamodb_volunteers.table_name
}

output "volunteers_table_arn" {
  description = "ARN da tabela DynamoDB de voluntários."
  value       = module.dynamodb_volunteers.table_arn
}
