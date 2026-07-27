variable "table_name" {
  description = "Nome da tabela DynamoDB."
  type        = string
}

variable "tags" {
  description = "Tags padrão."
  type        = map(string)
}

resource "aws_dynamodb_table" "this" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "volunteer_id"

  attribute {
    name = "volunteer_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = var.tags
}

output "table_name" {
  description = "Nome da tabela."
  value       = aws_dynamodb_table.this.name
}

output "table_arn" {
  description = "ARN da tabela."
  value       = aws_dynamodb_table.this.arn
}
