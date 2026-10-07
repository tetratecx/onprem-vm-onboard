# Only the AzureRM provider: this stack can be planned and applied with Azure
# credentials alone, with no AWS or GCP configuration present anywhere.
#
# This separation matters: azurerm authenticates while it is being configured,
# not on first use, so merely having it in a configuration forces Azure
# credentials to exist - even for resources that are never created.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
