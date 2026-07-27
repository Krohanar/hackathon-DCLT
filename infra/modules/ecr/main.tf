variable "repositories" {
  description = "Lista de repositórios ECR que serão criados."
  type        = list(string)
}

variable "tags" {
  description = "Tags padrão FinOps aplicadas aos repositórios."
  type        = map(string)
}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Mantém somente as últimas 10 imagens para reduzir custo e sujeira operacional."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

output "repository_urls" {
  description = "URLs dos repositórios ECR criados."
  value = {
    for name, repo in aws_ecr_repository.this :
    name => repo.repository_url
  }
}
