terraform {
  backend "s3" {
    bucket         = "pharma-tf-state-873135413040"
    key            = "envs/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
  }
}
