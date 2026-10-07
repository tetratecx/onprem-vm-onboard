# Only the AWS provider: this stack can be planned and applied with AWS
# credentials alone, with no GCP or Azure configuration present anywhere.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}
