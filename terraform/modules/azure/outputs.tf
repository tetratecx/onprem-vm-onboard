locals {
  # Sorted so the lists are stable between runs; private instances first.
  instance_keys = sort(keys(local.instances))

  # The public instance that doubles as the way in, if there is one.
  jump_host_ip = (var.jump_host_key != null
    ? azurerm_linux_virtual_machine.vm[var.jump_host_key].public_ip_address
    : null
  )

  # Per instance: how it is reached. A public instance is addressed directly; a
  # private one through the jump host, or directly on its private address when
  # there is none and connectivity is assumed to exist (VPN, ExpressRoute).
  reach = {
    for k in local.instance_keys : k => {
      private = local.instances[k].private
      ip = (local.instances[k].private
        ? azurerm_linux_virtual_machine.vm[k].private_ip_address
        : azurerm_linux_virtual_machine.vm[k].public_ip_address
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
      name       = azurerm_linux_virtual_machine.vm[k].name
      id         = azurerm_linux_virtual_machine.vm[k].id
      placement  = local.instances[k].private ? "private" : "public"
      private_ip = azurerm_linux_virtual_machine.vm[k].private_ip_address
      public_ip  = local.instances[k].private ? null : azurerm_linux_virtual_machine.vm[k].public_ip_address
      zone       = var.location
      ssh_host   = local.reach[k].ip
      ssh_user   = var.admin_username
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
    name      = azurerm_linux_virtual_machine.vm[var.jump_host_key].name
    public_ip = local.jump_host_ip
    ssh_user  = var.admin_username
  } : null
}

output "network" {
  description = "The resource group, VNet and subnet created, plus the NAT address when any instance is private."
  value = {
    resource_group = azurerm_resource_group.this.name
    vnet_name      = azurerm_virtual_network.this.name
    vnet_cidr      = var.vnet_cidr
    vm_subnet_id   = azurerm_subnet.vm.id
    # The address the private instances' onboarding traffic appears to come from.
    egress_ip = local.any_private ? azurerm_public_ip.nat[0].ip_address : null
  }
}

output "ssh_commands" {
  description = "Ready-to-paste SSH commands, with ProxyJump where the instance needs it."
  value = [
    for k in local.instance_keys :
    local.reach[k].via_jump
    ? "ssh -J ${var.admin_username}@${local.jump_host_ip} ${var.admin_username}@${local.reach[k].ip}   # ${k}"
    : "ssh ${var.admin_username}@${local.reach[k].ip}   # ${k}"
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
    ? "KEYCLOAK_CLIENT_SECRET='<secret>' SSH_JUMP=${var.admin_username}@${local.jump_host_ip} ./push-to-vm.sh ${var.admin_username}@${local.reach[k].ip}   # ${k}"
    : "KEYCLOAK_CLIENT_SECRET='<secret>' ./push-to-vm.sh ${var.admin_username}@${local.reach[k].ip}   # ${k}"
  ]
}
