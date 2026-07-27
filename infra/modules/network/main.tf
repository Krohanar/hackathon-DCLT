variable "project_name" {
  description = "Nome do projeto."
  type        = string
}

variable "environment" {
  description = "Ambiente da aplicação."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR da VPC."
  type        = string
}

variable "availability_zones" {
  description = "AZs usadas pela VPC."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets públicas."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDRs das subnets privadas."
  type        = list(string)
}

variable "tags" {
  description = "Tags padrão."
  type        = map(string)
}

locals {
  cluster_name = "solidarytech-${lower(var.environment)}"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-igw"
  })
}

resource "aws_subnet" "public" {
  for_each = {
    for index, cidr in var.public_subnet_cidrs :
    index => cidr
  }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = var.availability_zones[tonumber(each.key)]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                      = "${var.project_name}-${var.environment}-public-${tonumber(each.key) + 1}"
    "kubernetes.io/role/elb"                 = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  })
}

resource "aws_subnet" "private" {
  for_each = {
    for index, cidr in var.private_subnet_cidrs :
    index => cidr
  }

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = var.availability_zones[tonumber(each.key)]

  tags = merge(var.tags, {
    Name                                               = "${var.project_name}-${var.environment}-private-${tonumber(each.key) + 1}"
    "kubernetes.io/role/internal-elb"                 = "1"
    "kubernetes.io/cluster/${local.cluster_name}"      = "shared"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-private-rt"
  })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

output "vpc_id" {
  description = "ID da VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas."
  value       = values(aws_subnet.public)[*].id
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas."
  value       = values(aws_subnet.private)[*].id
}
