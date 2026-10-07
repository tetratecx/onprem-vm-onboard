locals {
  # Sorted so the lists are stable between runs; private instances first.
  instance_keys = sort(keys(local.instances))

  # The public instance that doubles as the way in, if there is one.
  jump_host_ip = (var.jump_host_key != null
    ? try(google_compute_instance.vm[var.jump_host_key].network_interface[0].access_config[0].nat_ip, null)
    : null
  )

  # Per instance: how it is reached. A public instance is addressed directly; a
  # private one through the jump host, or directly on its private address when
  # there is none and connectivity is assumed to exist (VPN, IAP).
  reach = {
    for k in local.instance_keys : k => {
      private = local.instances[k].private
      ip = (local.instances[k].private
        ? google_compute_instance.vm[k].network_interface[0].network_ip
        : try(google_compute_instance.vm[k].network_interface[0].access_config[0].nat_ip, null)
      )
      via_jump = local.instances[k].private && var.jump_host_key != null
    }
  }
}

output "instances" {
  description = "Every instance created, with its placement and what is needed to reach it."
  value = [
    for k in local.instance_keys : {
      key        = k
      name       = google_compute_instance.vm[k].name
      id         = google_compute_instance.vm[k].id
      placement  = local.instances[k].private ? "private" : "public"
      private_ip = google_compute_instance.vm[k].network_interface[0].network_ip
      public_ip  = try(google_compute_instance.vm[k].network_interface[0].access_config[0].nat_ip, null)
      zone       = google_compute_instance.vm[k].zone
      ssh_host   = local.reach[k].ip
      ssh_user   = local.ssh_user
      ssh_via    = local.reach[k].via_jump ? local.jump_host_ip : null
      # True for the public instance that is also the way in. It is onboarded
      # like any other - this is a role it carries, not a dedicated bastion.
      is_jump_host = k == var.jump_host_key
    }
  ]
}

output "jump_host" {
  description = <<-EOT
    The public mesh VM that private instances are reached through, or null when
    there is none. It is a full workload, not an idle bastion.
  EOT
  value = var.jump_host_key != null ? {
    key       = var.jump_host_key
    name      = google_compute_instance.vm[var.jump_host_key].name
    public_ip = local.jump_host_ip
    ssh_user  = local.ssh_user
  } : null
}

output "network" {
  description = "The VPC and subnet created, plus the Cloud NAT router when any instance is private."
  value = {
    network_name = google_compute_network.this.name
    network_id   = google_compute_network.this.id
    subnet_name  = google_compute_subnetwork.this.name
    subnet_cidr  = google_compute_subnetwork.this.ip_cidr_range
    # Cloud NAT allocates its addresses automatically, so there is no single
    # egress IP to print. Read them with:
    #   gcloud compute routers get-nat-mapping-info <router> --region <region>
    nat_router = local.any_private ? google_compute_router.nat[0].name : null
  }
}

output "ssh_commands" {
  description = "Ready-to-paste SSH commands, with ProxyJump where the instance needs it."
  value = [
    for k in local.instance_keys :
    local.reach[k].via_jump
    ? "ssh -J ${local.ssh_user}@${local.jump_host_ip} ${local.ssh_user}@${local.reach[k].ip}   # ${k}"
    : "ssh ${local.ssh_user}@${local.reach[k].ip}   # ${k}"
  ]
}

output "onboard_commands" {
  description = <<-EOT
    The vm/push-to-vm.sh invocation for each instance, including the jump host
    itself. Run them from the vm/ directory. Add SSH_KEY=<path to the private
    key> if your key is not the one ssh picks by default; SSH_JUMP is what sends
    the private instances through the public one.
  EOT
  value = [
    for k in local.instance_keys :
    local.reach[k].via_jump
    ? "KEYCLOAK_CLIENT_SECRET='<secret>' SSH_JUMP=${local.ssh_user}@${local.jump_host_ip} ./push-to-vm.sh ${local.ssh_user}@${local.reach[k].ip}   # ${k}"
    : "KEYCLOAK_CLIENT_SECRET='<secret>' ./push-to-vm.sh ${local.ssh_user}@${local.reach[k].ip}   # ${k}"
  ]
}
