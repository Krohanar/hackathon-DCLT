variable "cluster_name" {
  description = "Nome do cluster EKS."
  type        = string
}

variable "cluster_version" {
  description = "Versão Kubernetes do EKS."
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets públicas usadas pelos nodes."
  type        = list(string)
}

variable "donations_queue_arn" {
  description = "ARN da fila SQS de doações."
  type        = string
}

variable "volunteers_table_arn" {
  description = "ARN da tabela DynamoDB de voluntários."
  type        = string
}

variable "node_instance_types" {
  description = "Tipos de instância dos worker nodes."
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_desired_size" {
  description = "Quantidade desejada de nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Quantidade mínima de nodes."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Quantidade máxima de nodes."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags padrão."
  type        = map(string)
}

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-cluster-role"
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-node-role"
  })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "node_app_runtime_policy" {
  name = "${var.cluster_name}-node-app-runtime-policy"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowDonationQueueAccess"
        Effect = "Allow"
        Action = [
          "sqs:GetQueueUrl",
          "sqs:GetQueueAttributes",
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage"
        ]
        Resource = var.donations_queue_arn
      },
      {
        Sid    = "AllowVolunteerTableAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Scan",
          "dynamodb:Query"
        ]
        Resource = var.volunteers_table_arn
      }
    ]
  })
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = var.public_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  tags = merge(var.tags, {
    Name = var.cluster_name
  })

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-default-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.public_subnet_ids

  capacity_type  = "ON_DEMAND"
  instance_types = var.node_instance_types
  disk_size      = 20

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-default-ng"
  })

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
    aws_iam_role_policy.node_app_runtime_policy
  ]
}

output "cluster_name" {
  description = "Nome do cluster EKS."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint do cluster EKS."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Versão Kubernetes do cluster."
  value       = aws_eks_cluster.this.version
}

output "node_group_name" {
  description = "Nome do node group."
  value       = aws_eks_node_group.default.node_group_name
}

output "cluster_role_arn" {
  description = "ARN da role do cluster."
  value       = aws_iam_role.cluster.arn
}

output "node_role_arn" {
  description = "ARN da role dos nodes."
  value       = aws_iam_role.node.arn
}
