variable "queue_name" {
  description = "Nome da fila SQS."
  type        = string
}

variable "tags" {
  description = "Tags padrão."
  type        = map(string)
}

resource "aws_sqs_queue" "this" {
  name                       = var.queue_name
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true

  tags = var.tags
}

output "queue_url" {
  description = "URL da fila SQS."
  value       = aws_sqs_queue.this.url
}

output "queue_arn" {
  description = "ARN da fila SQS."
  value       = aws_sqs_queue.this.arn
}
