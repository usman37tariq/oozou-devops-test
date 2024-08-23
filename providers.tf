terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.0.2"
    }
  }
}

# Provider Configuration for AWS and Docker
provider "aws" {
  region  = var.region
  profile = var.profile
}

provider "docker" {
  registry_auth {
    address  = data.aws_ecr_authorization_token.ecr_token.proxy_endpoint
    username = data.aws_ecr_authorization_token.ecr_token.user_name
    password = data.aws_ecr_authorization_token.ecr_token.password
  }
}

# Data source to get the ECR authorization token
data "aws_ecr_authorization_token" "ecr_token" {}
