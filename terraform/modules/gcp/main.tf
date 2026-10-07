# GCP: a custom-mode VPC with one subnet. When the instances are private they
# get no external address, and egress goes through Cloud NAT.

locals {
  name = var.name_prefix

  # GCP labels must be lowercase, and may hold only letters, digits, - and _.
  labels = {
    for k, v in var.labels :
    lower(replace(k, "/[^a-zA-Z0-9_-]/", "-")) => lower(replace(v, "/[^a-zA-Z0-9_-]/", "-"))
  }

  images = {
    rhel9          = "rhel-cloud/rhel-9"
    rhel8          = "rhel-cloud/rhel-8"
    rocky9         = "rocky-linux-cloud/rocky-linux-9"
    centos-stream9 = "centos-cloud/centos-stream-9"
  }
  image = coalesce(var.image, local.images[var.os])

  # GCP has no per-image login account: the username comes from the ssh-keys
  # metadata entry. We pick a fixed one so the outputs can be exact.
  ssh_user = "tsbadmin"

  # Network tags are how firewall rules select instances.
  vm_tag = "${local.name}-vm"

  # One entry per instance, keyed by a stable name, so changing a count adds or
  # removes only that instance instead of renumbering the rest.
  instances = merge(
    {
      for i in range(var.private_instance_count) :
      "private-${i + 1}" => { private = true, ordinal = i }
    },
    {
      for i in range(var.public_instance_count) :
      "public-${i + 1}" => { private = false, ordinal = i }
    },
  )

  any_private = var.private_instance_count > 0
  any_public  = var.public_instance_count > 0

}

# --- network ----------------------------------------------------------------

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = local.name
  auto_create_subnetworks = false
  description             = "TSB mesh VM onboarding"
}

resource "google_compute_subnetwork" "this" {
  project       = var.project_id
  name          = local.name
  network       = google_compute_network.this.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr

  # Lets a private instance be reached by GCP-managed services and shows flow
  # logs for the onboarding traffic; harmless when the instances are public.
  private_ip_google_access = true
}

# --- Cloud NAT --------------------------------------------------------------
# Only when the instances are private: this is what gives them outbound access
# to the vmgateway and Keycloak without an external address.

resource "google_compute_router" "nat" {
  count = local.any_private ? 1 : 0

  project = var.project_id
  name    = "${local.name}-nat"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count = local.any_private ? 1 : 0

  project = var.project_id
  name    = "${local.name}-nat"
  router  = google_compute_router.nat[0].name
  region  = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- firewall ---------------------------------------------------------------

# SSH from the allowed CIDRs, to every instance.
#
# For a public instance this is the way in - including the one acting as jump
# host. For a private instance the rule is unreachable from those CIDRs, so it
# costs nothing to keep; and with no jump host it is what lets an existing VPN
# or IAP range reach them.
resource "google_compute_firewall" "ssh" {
  project       = var.project_id
  name          = "${local.name}-ssh"
  network       = google_compute_network.this.name
  description   = "SSH to the instances from the allowed CIDRs"
  direction     = "INGRESS"
  source_ranges = var.ssh_allowed_cidrs
  target_tags   = [local.vm_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}


# How the TSB cluster reaches the sidecar and the application.
resource "google_compute_firewall" "mesh" {
  count = length(var.mesh_allowed_cidrs) > 0 ? 1 : 0

  project       = var.project_id
  name          = "${local.name}-mesh"
  network       = google_compute_network.this.name
  description   = "mesh and application ports from the cluster"
  direction     = "INGRESS"
  source_ranges = var.mesh_allowed_cidrs
  target_tags   = [local.vm_tag]

  allow {
    protocol = "tcp"
    ports    = [for p in var.mesh_ports : tostring(p)]
  }
}

resource "google_compute_firewall" "internal" {
  project       = var.project_id
  name          = "${local.name}-internal"
  network       = google_compute_network.this.name
  description   = "traffic within the subnet, including the jump host reaching SSH on the private instances"
  direction     = "INGRESS"
  source_ranges = [var.subnet_cidr]
  target_tags   = [local.vm_tag]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# --- instances --------------------------------------------------------------

resource "google_compute_instance" "vm" {
  for_each = local.instances

  project      = var.project_id
  name         = "${local.name}-${each.key}"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [local.vm_tag]
  labels = merge(local.labels, {
    role      = "mesh-vm"
    placement = each.value.private ? "private" : "public"
  })

  boot_disk {
    initialize_params {
      image = local.image
      size  = var.root_volume_size
      type  = "pd-balanced"
      # Disks are a separately-labelled resource in GCP, so the governance
      # labels have to be set here as well as on the instance.
      labels = local.labels
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id

    # An access_config block is what gives an instance an external IP. Omitting
    # it is how an instance stays private - its egress then goes through Cloud
    # NAT. GCP has a single subnet here, so placement is decided by this block
    # alone rather than by which subnet the instance sits in.
    dynamic "access_config" {
      for_each = each.value.private ? [] : [1]
      content {}
    }
  }

  metadata = merge(
    { ssh-keys = "${local.ssh_user}:${var.ssh_public_key}" },
    # The two scripts differ only in CONNECTED_OVER, which must match where the
    # instance actually sits.
    each.value.private
    ? (var.user_data.private != "" ? { startup-script = var.user_data.private } : {})
    : (var.user_data.public != "" ? { startup-script = var.user_data.public } : {}),
  )

  # Keep Terraform from fighting the guest agent over these.
  allow_stopping_for_update = true

  depends_on = [google_compute_router_nat.this]
}

