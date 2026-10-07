output "cloud" {
  description = "Which cloud this stack built in."
  value       = "azure"
}

output "instances" {
  description = "Every instance created, with what is needed to reach and onboard it."
  value       = module.azure.instances
}

output "jump_host" {
  description = <<-EOT
    The public mesh VM that private instances are reached through, or null when
    there is none. It is onboarded and carries traffic like any other instance -
    there is no dedicated bastion.
  EOT
  value       = module.azure.jump_host
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
  description = "The resource group, VNet and subnets created, plus the NAT egress address when private."
  value       = module.azure.network
}

output "ssh_commands" {
  description = "Ready-to-paste SSH commands, with ProxyJump filled in for private instances."
  value       = module.azure.ssh_commands
}

output "onboard_commands" {
  description = "The vm/push-to-vm.sh invocation for each instance."
  value       = module.azure.onboard_commands
}

output "plane_uid" {
  description = "The plane UID these instances expect in the token's 'aud' claim."
  value       = module.bootstrap.plane_uid
}

output "connected_over" {
  description = "The CONNECTED_OVER value written into the instances' vm.env."
  value       = module.bootstrap.connected_over
}

output "applied_tags" {
  description = <<-EOT
    Exactly the tags put on every taggable resource in this stack, including the
    mandatory Tetrate ones. Check them before applying:
      terraform -chdir=stacks/azure output applied_tags
  EOT
  value       = local.common_tags
}
