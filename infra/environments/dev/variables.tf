variable "aws_region" {
  description = "Região AWS principal."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Ambiente da aplicação."
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Nome do projeto."
  type        = string
  default     = "SolidaryTech"
}

variable "cost_center" {
  description = "Centro de custo FinOps."
  type        = string
  default     = "NGO-Core"
}
