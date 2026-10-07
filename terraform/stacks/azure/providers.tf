provider "azurerm" {
  features {}

  # Null falls back to the normal credential chain: ARM_SUBSCRIPTION_ID, or the
  # Azure CLI's current subscription.
  subscription_id = var.subscription_id
}
