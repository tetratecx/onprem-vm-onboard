provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # Applied to every resource that supports labels, so a resource added later
  # cannot silently come up untagged. Resource-level labels merge on top.
  #
  # Note: GCP networks, subnetworks, firewall rules and Cloud Routers accept no
  # labels at all - that is a GCP limitation, not an omission here. Only
  # instances and disks carry them.
  default_labels = local.common_tags
}
