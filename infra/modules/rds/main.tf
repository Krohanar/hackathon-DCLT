variable "project_name" {
  description = "Nome do projeto."
  type        = string
}

variable "environment" {
  description = "Ambiente."
  type        = string
}

variable "vpc_id" {
  description = "ID da VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privadas onde o RDS ficará."
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDRs autorizados a acessar o PostgreSQL."
  type        = list(string)
}

variable "db_name" {
  description = "Nome do banco inicial."
  type        = string
  default     = "ngo_db"
}

variable "master_username" {
  description = "Usuário administrador do PostgreSQL."
  type        = string
  default     = "solidaryadmin"
}

variable "tags" {
  description = "Tags padrão."
  type        = map(string)
}

resource "random_password" "master" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_security_group" "rds" {
  name        = "solidarytech-${lower(var.environment)}-rds-sg"
  description = "Security group do RDS PostgreSQL da SolidaryTech"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL dentro da VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "Saida liberada"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "solidarytech-${lower(var.environment)}-rds-sg"
  })
}

resource "aws_db_subnet_group" "this" {
  name       = "solidarytech-${lower(var.environment)}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, {
    Name = "solidarytech-${lower(var.environment)}-db-subnet-group"
  })
}

resource "aws_db_instance" "postgres" {
  identifier = "solidarytech-${lower(var.environment)}-postgres"

  engine         = "postgres"
  instance_class = "db.t3.micro"

  db_name  = var.db_name
  username = var.master_username
  password = random_password.master.result

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  auto_minor_version_upgrade = true
  apply_immediately          = true

  deletion_protection = false
  skip_final_snapshot = true

  performance_insights_enabled = false
  monitoring_interval          = 0

  tags = merge(var.tags, {
    Name = "solidarytech-${lower(var.environment)}-postgres"
  })
}

output "db_instance_id" {
  description = "ID da instância RDS."
  value       = aws_db_instance.postgres.id
}

output "db_endpoint" {
  description = "Endpoint do RDS."
  value       = aws_db_instance.postgres.address
}

output "db_port" {
  description = "Porta do PostgreSQL."
  value       = aws_db_instance.postgres.port
}

output "db_name" {
  description = "Nome do banco inicial."
  value       = aws_db_instance.postgres.db_name
}

output "db_username" {
  description = "Usuário administrador."
  value       = aws_db_instance.postgres.username
}

output "db_password" {
  description = "Senha do usuário administrador."
  value       = random_password.master.result
  sensitive   = true
}

output "security_group_id" {
  description = "Security Group do RDS."
  value       = aws_security_group.rds.id
}
