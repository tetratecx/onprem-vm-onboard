locals {
  # Sorted so the lists are stable between runs; private instances first.
  instance_keys = sort(keys(local.instances))

  # The public instance that doubles as the way in, if there is one. It is an
  # ordinary mesh VM, so its address comes out of the same map as the rest.
  jump_host_ip = var.jump_host_key != null ? aws_instance.vm[var.jump_host_key].public_ip : null

  # Per instance: how it is reached. A public instance is addressed directly; a
  # private one through the jump host, or directly on its private address when
  # there is none and connectivity is assumed to exist (VPN, Direct Connect, SSM).
  reach = {
    for k in local.instance_keys : k => {
      private  = local.instances[k].private
      ip       = local.instances[k].private ? aws_instance.vm[k].private_ip : aws_instance.vm[k].public_ip
      via_jump = local.instances[k].private && var.jump_host_key != null
    }
  }
}

output "instances" {
  description = "Every instance created, with its placement and what is needed to reach it."
  value = [
    for k in local.instance_keys : {
      key        = k
      name       = aws_instance.vm[k].tags["Name"]
      id         = aws_instance.vm[k].id
      placement  = local.instances[k].private ? "private" : "public"
      private_ip = aws_instance.vm[k].private_ip
      public_ip  = aws_instance.vm[k].public_ip != "" ? aws_instance.vm[k].public_ip : null
      zone       = aws_instance.vm[k].availability_zone
      ssh_host   = local.reach[k].ip
      ssh_user   = local.ssh_user
      # The instance to jump through, or null when reached directly.
      ssh_via = local.reach[k].via_jump ? local.jump_host_ip : null
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
    name      = aws_instance.vm[var.jump_host_key].tags["Name"]
    public_ip = local.jump_host_ip
    ssh_user  = local.ssh_user
  } : null
}

output "network" {
  description = "The VPC and subnets created, plus the NAT egress address when any instance is private."
  value = {
    vpc_id             = aws_vpc.this.id
    vpc_cidr           = aws_vpc.this.cidr_block
    public_subnet_ids  = aws_subnet.public[*].id
    private_subnet_ids = aws_subnet.private[*].id
    # The address the private instances' onboarding traffic appears to come
    # from. Allow it wherever Keycloak or the vmgateway filters by source.
    egress_ip = local.any_private ? aws_eip.nat[0].public_ip : null
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
