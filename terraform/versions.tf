# Which Terraform and which AWS plugin ("provider") this code needs.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # any 6.x, never a breaking 7.0
    }
  }

  # State stays in a local file (terraform.tfstate, git-ignored).
  # A team would use an S3 backend here instead.
}

provider "aws" {
  region = var.region

  # Every resource gets these tags automatically (the console needed them typed by hand).
  default_tags {
    tags = {
      project = "station-stream"
      app     = var.name
      managed = "terraform"
    }
  }
}

data "aws_caller_identity" "me" {}

