output "cloud" {
  description = "Which cloud this stack built in."
  value       = "gcp"
}

output "instances" {
  description = "Every instance created, with what is needed to reach and onboard it."
  value       = module.gcp.instances
}

output "jump_host" {
  description = <<-EOT
    The public mesh VM that private instances are reached through, or null when
    there is none. It is onboarded and carries traffic like any other instance -
    there is no dedicated bastion.
  EOT
  value       = module.gcp.jump_host
}

output "placement" {
  description = <<-EOT
    What was built and why, so the instance count is never a surprise: a public
    instance is added when private ones need a way in and none was requested.
  EOT
  value = {
    private_instances = local.private_count
    public_instances  = local.public_count
    total             = local.private_count + local.public_count
    jump_host         = local.jump_host_key
    # True when one public instance exists only to provide the way in.
    public_instance_added_for_access = local.jump_host_added
  }
}

output "network" {
  description = "The VPC and subnet created, plus the Cloud NAT router when private."
  value       = module.gcp.network
}

output "ssh_commands" {
  description = "Ready-to-paste SSH commands, with ProxyJump filled in for private instances."
  value       = module.gcp.ssh_commands
}

output "onboard_commands" {
  description = "The vm/push-to-vm.sh invocation for each instance."
  value       = module.gcp.onboard_commands
}

output "plane_uid" {
  description = "The plane UID these instances expect in the token's 'aud' claim."
  value       = module.bootstrap.plane_uid
}

output "connected_over" {
  description = "The CONNECTED_OVER value written into the instances' vm.env."
  value       = module.bootstrap.connected_over
}

output "applied_labels" {
  description = <<-EOT
    Exactly the labels put on every label-supporting resource in this stack,
    after the conversion GCP requires: label values accept only lowercase
    letters, digits, '-' and '_', so "sales:ce" is applied as "sales-ce".
    Compare with tetrate_tags to see what changed.

    GCP networks, subnetworks, firewall rules and Cloud Routers accept no labels
    at all, so only the instances and their disks carry these.
  EOT
  value       = local.common_tags
}

output "labels_rewritten_for_gcp" {
  description = "Only the labels whose value GCP would not accept verbatim, as requested -> applied."
  value = {
    for k, v in local.raw_labels :
    k => { requested = v, applied = lower(replace(v, "/[^a-zA-Z0-9_-]/", "-")) }
    if lower(replace(v, "/[^a-zA-Z0-9_-]/", "-")) != v
  }
}

output "project" {
  description = "The project these resources live in, and whether Terraform manages it."
  value = {
    project_id = var.project_id
    # Only set when Terraform created the project.
    project_number  = try(google_project.this[0].number, null)
    managed         = var.create_project
    deletion_policy = var.create_project ? var.project_deletion_policy : null
  }
}
