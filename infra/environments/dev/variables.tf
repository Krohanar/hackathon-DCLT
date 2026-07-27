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

variable "vpc_cidr" {
  description = "CIDR principal da VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "availability_zones" {
  description = "Availability Zones usadas."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets pÃºblicas."
  type        = list(string)
  default     = ["10.40.1.0/24", "10.40.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs das subnets privadas."
  type        = list(string)
  default     = ["10.40.11.0/24", "10.40.12.0/24"]
}

variable "eks_cluster_version" {
  description = "VersÃ£o Kubernetes do EKS."
  type        = string
  default     = "1.36"
}

variable "eks_node_instance_types" {
  description = "Tipos de instÃ¢ncia dos nodes EKS."
  type        = list(string)
  default     = ["t3.small"]
}

variable "eks_node_desired_size" {
  description = "Quantidade desejada de nodes EKS."
  type        = number
  default     = 4
}

variable "eks_node_min_size" {
  description = "Quantidade mÃ­nima de nodes EKS."
  type        = number
  default     = 2
}

variable "eks_node_max_size" {
  description = "Quantidade mÃ¡xima de nodes EKS."
  type        = number
  default     = 4
}
