terraform {
  backend "s3" {
    bucket         = "pharma-tf-state"
    key            = "global/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "pharma-tf-lock"
    encrypt        = true
  }
}
