locals {
  # The Tetrate governance tags come first and are not overridable by var.tags:
  # the accounts reject resources without them, so they must survive any merge.
  common_tags = merge(
    {
      project    = "tsb-vm-onboarding"
      managed-by = "terraform"
      stack      = "aws"
    },
    var.tags,
    var.tetrate_tags,
  )

  ssh_public_key = trimspace(
    coalesce(var.ssh_public_key, try(file(pathexpand(var.ssh_public_key_path)), null), "")
  )

  # Placement, per instance.
  #
  # The simple path: instance_count instances, all in the placement that the
  # shared private_instances flag selects.
  #
  # The explicit path: setting either count splits them, and instance_count and
  # private_instances no longer apply to this stack.
  explicit_split = var.private_instance_count != null || var.public_instance_count != null

  private_count = (local.explicit_split
    ? coalesce(var.private_instance_count, 0)
    : (var.private_instances ? var.instance_count : 0)
  )

  requested_public = (local.explicit_split
    ? coalesce(var.public_instance_count, 0)
    : (var.private_instances ? 0 : var.instance_count)
  )

  # A private instance has no inbound path from outside, so something in the
  # public subnet has to be jumped through. Rather than a bastion that sits idle,
  # one of the public mesh VMs takes that job - and if the counts asked for none,
  # one is added. It is onboarded and carries traffic like any other instance.
  needs_jump_host = local.private_count > 0 && var.public_jump_host
  public_count    = local.needs_jump_host ? max(local.requested_public, 1) : local.requested_public

  # Which instance is the way in. The module only needs the decision, not the
  # policy behind it.
  jump_host_key = local.needs_jump_host ? "public-1" : null

  # True when a public instance was added purely to provide the way in, which is
  # worth surfacing because it is one more instance than was asked for.
  jump_host_added = local.needs_jump_host && local.requested_public == 0
}

# Renders the cloud-init script and the vm.env that goes with it. No provider of
# its own, so it is shared by all three stacks.
module "bootstrap" {
  source = "../../modules/bootstrap"

  enabled    = var.prepare_onboarding
  onboarding = var.onboarding
}

module "aws" {
  source = "../../modules/aws"

  name_prefix            = var.name_prefix
  tags                   = local.common_tags
  private_instance_count = local.private_count
  public_instance_count  = local.public_count
  instance_type          = var.instance_type
  availability_zones     = var.availability_zones
  os                     = var.os
  ami_id                 = var.ami_id
  root_volume_size       = var.root_volume_size
  vpc_cidr               = var.vpc_cidr

  jump_host_key = local.jump_host_key

  ssh_public_key     = local.ssh_public_key
  ssh_allowed_cidrs  = var.ssh_allowed_cidrs
  mesh_allowed_cidrs = var.mesh_allowed_cidrs
  mesh_ports         = var.mesh_ports

  user_data = module.bootstrap.user_data
}

# Fail with a readable message rather than deep inside a provider call.
resource "terraform_data" "preconditions" {
  input = var.name_prefix

  lifecycle {
    precondition {
      condition     = local.ssh_public_key != ""
      error_message = "No SSH public key: set ssh_public_key, or point ssh_public_key_path at an existing file."
    }
  }
}
