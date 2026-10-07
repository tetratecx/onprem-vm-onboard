locals {
  raw_labels = merge(
    {
      project    = "tsb-vm-onboarding"
      managed-by = "terraform"
      stack      = "gcp"
    },
    var.tags,
    # The Tetrate governance tags come last so nothing can override them.
    var.tetrate_tags,
  )

  # GCP labels accept only lowercase letters, digits, '-' and '_', in both keys
  # and values, so "sales:ce" has to become "sales-ce". The conversion happens
  # here, once, and the result is published as the applied_labels output so it
  # can be checked against the tag policy.
  common_tags = {
    for k, v in local.raw_labels :
    lower(replace(k, "/[^a-zA-Z0-9_-]/", "-")) => lower(replace(v, "/[^a-zA-Z0-9_-]/", "-"))
  }

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

module "bootstrap" {
  source = "../../modules/bootstrap"

  enabled    = var.prepare_onboarding
  onboarding = var.onboarding
}

module "gcp" {
  source = "../../modules/gcp"

  # Nothing inside the project can be created until the project exists and the
  # Compute Engine API is on. Both are no-ops when create_project is false.
  depends_on = [google_project.this, google_project_service.this]

  name_prefix            = var.name_prefix
  labels                 = local.common_tags
  project_id             = var.project_id
  region                 = var.region
  zone                   = var.zone
  private_instance_count = local.private_count
  public_instance_count  = local.public_count
  machine_type           = var.machine_type
  os                     = var.os
  image                  = var.image
  root_volume_size       = var.root_volume_size
  subnet_cidr            = var.subnet_cidr

  jump_host_key = local.jump_host_key

  ssh_public_key     = local.ssh_public_key
  ssh_allowed_cidrs  = var.ssh_allowed_cidrs
  mesh_allowed_cidrs = var.mesh_allowed_cidrs
  mesh_ports         = var.mesh_ports

  user_data = module.bootstrap.user_data
}

resource "terraform_data" "preconditions" {
  input = var.name_prefix

  lifecycle {
    precondition {
      condition     = local.ssh_public_key != ""
      error_message = "No SSH public key: set ssh_public_key, or point ssh_public_key_path at an existing file."
    }
    precondition {
      condition     = !var.create_project || var.org_id != null || var.folder_id != null
      error_message = "create_project is true, so one of org_id or folder_id must be set. Find the organisation with: gcloud organizations list"
    }
    precondition {
      condition     = !var.create_project || var.billing_account != null
      error_message = "create_project is true, so billing_account must be set - without billing the Compute Engine API cannot be used. List them with: gcloud billing accounts list"
    }
    precondition {
      condition     = !(var.org_id != null && var.folder_id != null)
      error_message = "Set org_id or folder_id, not both: a project has exactly one parent."
    }
  }
}
