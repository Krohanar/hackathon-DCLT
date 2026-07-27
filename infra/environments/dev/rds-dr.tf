resource "aws_kms_key" "rds_dr" {
  provider = aws.dr

  description             = "Chave de criptografia dos backups cross-region do RDS SolidaryTech."
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = merge(local.common_tags, {
    Name    = "solidarytech-rds-dr-key"
    Purpose = "RDS Disaster Recovery"
  })
}

resource "aws_kms_alias" "rds_dr" {
  provider = aws.dr

  name          = "alias/solidarytech-rds-dr"
  target_key_id = aws_kms_key.rds_dr.key_id
}

resource "aws_db_instance_automated_backups_replication" "postgres_dr" {
  provider = aws.dr

  source_db_instance_arn = "arn:aws:rds:us-east-1:106978078844:db:solidarytech-production-postgres"
  kms_key_id             = aws_kms_key.rds_dr.arn
  retention_period       = 7
}
