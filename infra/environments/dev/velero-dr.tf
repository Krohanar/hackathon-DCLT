variable "velero_dr_region" {
  description = "Região secundária utilizada para armazenar os backups do Velero."
  type        = string
  default     = "us-west-2"
}

provider "aws" {
  alias  = "dr"
  region = var.velero_dr_region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "velero_current" {}

data "aws_eks_cluster" "velero_cluster" {
  name = module.eks.cluster_name
}

locals {
  velero_dr_bucket_name = "solidarytech-velero-dr-${data.aws_caller_identity.velero_current.account_id}-${var.velero_dr_region}"

  velero_oidc_issuer = data.aws_eks_cluster.velero_cluster.identity[0].oidc[0].issuer

  velero_oidc_provider_path = replace(
    local.velero_oidc_issuer,
    "https://",
    ""
  )

  velero_service_account_subject = "system:serviceaccount:velero:velero"
}

resource "aws_iam_openid_connect_provider" "eks" {
  url = local.velero_oidc_issuer

  client_id_list = [
    "sts.amazonaws.com"
  ]

  tags = merge(local.common_tags, {
    Name    = "solidarytech-production-eks-oidc"
    Purpose = "Velero IRSA"
  })
}

resource "aws_s3_bucket" "velero_dr" {
  provider = aws.dr

  bucket        = local.velero_dr_bucket_name
  force_destroy = false

  tags = merge(local.common_tags, {
    Name          = local.velero_dr_bucket_name
    Purpose       = "Velero Disaster Recovery"
    PrimaryRegion = var.aws_region
    DRRegion      = var.velero_dr_region
  })
}

resource "aws_s3_bucket_ownership_controls" "velero_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.velero_dr.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "velero_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.velero_dr.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "velero_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.velero_dr.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.velero_dr.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "velero_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.velero_dr.id

  depends_on = [
    aws_s3_bucket_versioning.velero_dr
  ]

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-old-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_iam_role" "velero" {
  name = "solidarytech-velero-dr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AllowVeleroServiceAccount"
        Effect = "Allow"

        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }

        Action = "sts:AssumeRoleWithWebIdentity"

        Condition = {
          StringEquals = {
            "${local.velero_oidc_provider_path}:aud" = "sts.amazonaws.com"
            "${local.velero_oidc_provider_path}:sub" = local.velero_service_account_subject
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name    = "solidarytech-velero-dr-role"
    Purpose = "Velero IRSA"
  })
}

resource "aws_iam_policy" "velero_s3" {
  name        = "solidarytech-velero-dr-s3-policy"
  description = "Permite ao Velero armazenar e restaurar backups no bucket S3 de DR."

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AllowBucketMetadata"
        Effect = "Allow"

        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:ListBucketVersions"
        ]

        Resource = aws_s3_bucket.velero_dr.arn
      },
      {
        Sid    = "AllowBackupObjectOperations"
        Effect = "Allow"

        Action = [
          "s3:AbortMultipartUpload",
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListMultipartUploadParts",
          "s3:PutObject",
          "s3:PutObjectTagging"
        ]

        Resource = "${aws_s3_bucket.velero_dr.arn}/*"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name    = "solidarytech-velero-dr-s3-policy"
    Purpose = "Velero Disaster Recovery"
  })
}

resource "aws_iam_role_policy_attachment" "velero_s3" {
  role       = aws_iam_role.velero.name
  policy_arn = aws_iam_policy.velero_s3.arn
}

output "velero_dr_bucket_name" {
  description = "Nome do bucket S3 cross-region utilizado pelo Velero."
  value       = aws_s3_bucket.velero_dr.bucket
}

output "velero_dr_bucket_region" {
  description = "Região do bucket de Disaster Recovery."
  value       = var.velero_dr_region
}

output "velero_iam_role_arn" {
  description = "IAM Role utilizada pelo ServiceAccount do Velero."
  value       = aws_iam_role.velero.arn
}

output "eks_oidc_provider_arn" {
  description = "ARN do IAM OIDC Provider associado ao EKS."
  value       = aws_iam_openid_connect_provider.eks.arn
}
