# Only the Google provider: this stack can be planned and applied with GCP
# credentials alone, with no AWS or Azure configuration present anywhere.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
