variable "aws_region" {
  description = "RegiÃ£o AWS principal."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Ambiente da aplicaÃ§Ã£o."
  type        = string
  default     = "Production"
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
