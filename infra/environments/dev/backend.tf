terraform {
  backend "s3" {
    bucket         = "solidarytech-tfstate-106978078844-us-east-1"
    key            = "solidarytech/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "solidarytech-terraform-locks"
    encrypt        = true
  }
}
