# Optionally create the GCP project itself, so a demo environment can be stood
# up and torn down in one piece.
#
# Off by default: creating a project is an organisation-level action, and most
# runs target a project that already exists. Turn it on with
# create_project = true, which also needs org_id (or folder_id) and
# billing_account.
#
# Note that GCP never releases a project ID, even after the project is deleted -
# a destroyed project cannot be recreated under the same name. Pick the ID with
# that in mind.

resource "google_project" "this" {
  count = var.create_project ? 1 : 0

  project_id = var.project_id
  name       = coalesce(var.project_name, var.project_id)

  # Exactly one parent: a project may sit under an organisation or a folder.
  org_id    = var.folder_id == null ? var.org_id : null
  folder_id = var.folder_id

  # Without a billing account the Compute Engine API cannot be used, so the
  # instances would fail even though the project exists.
  billing_account = var.billing_account

  labels = local.common_tags

  # GCP creates a "default" VPC with every new project. The module builds its own
  # network and never uses it, but this is left on: it is a create-time-only
  # field, so flipping it on an existing project would mean replacing the
  # project, which the ID reservation above makes irreversible.
  auto_create_network = true

  # The provider defaults this to PREVENT, which makes `terraform destroy` leave
  # the project behind - defeating the point of a disposable environment.
  deletion_policy = var.project_deletion_policy
}

# The APIs the instances need. Without compute.googleapis.com the first network
# call fails with a confusing 403.
resource "google_project_service" "this" {
  for_each = var.create_project ? toset(var.project_services) : toset([])

  project = google_project.this[0].project_id
  service = each.key

  # Disabling an API on the way out is slow and pointless when the whole project
  # is being deleted anyway.
  disable_on_destroy = false
}
