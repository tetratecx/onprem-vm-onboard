# ---------------------------------------------------------------------------
# Shared settings
#
# These are identical in all three stacks, so one common.tfvars can be passed to
# every one of them. deploy.sh does exactly that.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for every resource name, so parallel runs do not collide."
  type        = string
  default     = "tsb-vm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be 2-21 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "tags" {
  description = "Extra tags/labels applied to everything, on top of tetrate_tags and the defaults."
  type        = map(string)
  default     = {}
}

variable "tetrate_tags" {
  description = <<-EOT
    The Tetrate governance tags. These are MANDATORY: the sandbox accounts refuse
    to create resources without them, so a missing or empty value fails the apply
    rather than producing an untagged resource.

    Every value is overridable from tfvars; override only the ones you need, the
    rest keep the defaults below.

    Note for GCP: label values there may only contain lowercase letters, digits,
    '-' and '_', so a value like "sales:ce" is written as "sales-ce". The GCP
    stack does that conversion itself and reports the result in its
    applied_labels output.
  EOT
  type = object({
    tetrate_owner    = optional(string, "nizam")
    tetrate_team     = optional(string, "sales:ce")
    tetrate_purpose  = optional(string, "demo")
    tetrate_lifespan = optional(string, "ongoing")
    tetrate_customer = optional(string, "apigw-demo")
  })
  default = {}

  validation {
    condition     = alltrue([for k, v in var.tetrate_tags : trimspace(v) != ""])
    error_message = "Every tetrate_tags value must be non-empty: the cloud accounts reject untagged resources. Check tetrate_owner, tetrate_team, tetrate_purpose, tetrate_lifespan and tetrate_customer."
  }
}

variable "private_instances" {
  description = <<-EOT
    false (default): instances sit in a public subnet with a public IP, and the
    onboarding traffic leaves directly.

    true: instances sit in a private subnet with no public IP, and all outbound
    traffic - the package download from the vmgateway and the Keycloak token
    requests - leaves through a managed NAT gateway. Nothing can reach the
    instances from the internet, so one of the public mesh VMs is designated the
    SSH jump host - see public_jump_host.
  EOT
  type        = bool
  default     = false
}

variable "public_jump_host" {
  description = <<-EOT
    How private instances are reached over SSH.

    true (default): one of the public instances doubles as the SSH jump host. If
    the counts ask for no public instance, one is added - so "2 private" really
    creates 3 instances: 2 private plus 1 public. That public instance is a full
    mesh VM like any other - it is onboarded, runs the workload and carries mesh
    traffic - it just also happens to be the way in. There is no separate,
    idle bastion.

    false: no instance is added and nothing is designated a jump host. Private
    instances then accept SSH straight from ssh_allowed_cidrs, which is what you
    want when connectivity already exists (VPN, Direct Connect, SSM, IAP,
    Azure Bastion).

    Ignored when every instance is public: they are reachable directly.
  EOT
  type        = bool
  default     = true
}

variable "ssh_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach SSH. They reach the public instances directly,
    including the one acting as jump host; the private instances are reached
    through it. Required and deliberately without a default:
    set it to your own address, e.g. ["203.0.113.4/32"]. Use ["0.0.0.0/0"] only
    for a throwaway lab.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "ssh_allowed_cidrs must list at least one CIDR, otherwise the instances are unreachable."
  }
}

variable "mesh_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the mesh and application ports on the instances. This
    is how the TSB cluster reaches an onboarded VM, so it must cover the
    addresses the cluster sends from. Empty opens no inbound mesh traffic, which
    is right only when the VM makes outbound calls exclusively.
  EOT
  type        = list(string)
  default     = []
}

variable "mesh_ports" {
  description = <<-EOT
    Inbound TCP ports opened to mesh_allowed_cidrs.
      15008  HBONE, how the mesh delivers traffic to the sidecar
      15006  inbound capture
      15021  sidecar health
      15020  sidecar metrics/readiness
      8000   the application behind the sidecar (05-sidecar.yaml defaultEndpoint)
      3000   the demo app's TCP port
  EOT
  type        = list(number)
  default     = [15008, 15006, 15021, 15020, 8000, 3000]
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key to install. Ignored when ssh_public_key is set."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_public_key" {
  description = "The SSH public key itself, if you would rather not point at a file."
  type        = string
  default     = null
}

variable "prepare_onboarding" {
  description = <<-EOT
    true (default): cloud-init installs what the onboarding needs (curl, gettext,
    libcap, python3) and writes a ready-to-use vm.env to /opt/vm-onboarding/. The
    instance is then one push-to-vm.sh away from being a mesh workload.

    false: plain instances, nothing installed.
  EOT
  type        = bool
  default     = true
}

variable "onboarding" {
  description = <<-EOT
    What the instances are prepared for; becomes /opt/vm-onboarding/vm.env. These
    mirror vm/vm.env, and the defaults are placeholders - set at least
    vm_endpoint, keycloak_realm_url and keycloak_client_id.

    The Keycloak client SECRET is deliberately not here: it would be stored in
    clear text in the Terraform state. Pass it at install time instead.

    connected_over: leave unset to derive it from the placement - VPC for
    private instances, INTERNET for public ones.
  EOT
  type = object({
    vm_endpoint              = optional(string, "vms.cluster.example.com")
    onboarding_plane_uid     = optional(string, null)
    onboarding_tls_insecure  = optional(bool, true)
    workload_group_namespace = optional(string, "payments")
    workload_group_name      = optional(string, "payments-v1")
    connected_over           = optional(string, null)
    keycloak_realm_url       = optional(string, "https://keycloak.example.com/realms/tetrate")
    keycloak_client_id       = optional(string, "vm-write")
    install_obstester        = optional(bool, true)
  })
  default = {}

  validation {
    condition     = var.onboarding.connected_over == null || contains(["INTERNET", "VPC"], coalesce(var.onboarding.connected_over, "VPC"))
    error_message = "onboarding.connected_over must be \"INTERNET\", \"VPC\", or unset to derive it from the placement."
  }
}

# ---------------------------------------------------------------------------
# GCP-specific
# ---------------------------------------------------------------------------

variable "project_id" {
  description = <<-EOT
    The GCP project to build in. Required.

    With create_project = false (the default) it must already exist:
      gcloud projects list
    With create_project = true it is the ID Terraform will create.
  EOT
  type        = string
}

variable "region" {
  description = "GCP region for the subnet and Cloud NAT."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the instances."
  type        = string
  default     = "us-central1-a"
}

variable "instance_count" {
  description = <<-EOT
    How many mesh VMs to create; they all take the placement set by
    private_instances. 0 creates the network but no instances.

    Ignored when private_instance_count or public_instance_count is set, which is
    how a single stack gets a mix of both placements.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 0
    error_message = "instance_count cannot be negative."
  }
}

variable "machine_type" {
  description = "GCE machine type."
  type        = string
  default     = "e2-medium"
}

variable "os" {
  description = "Stock image family: rhel9, rhel8, rocky9 or centos-stream9. Overridden by image."
  type        = string
  default     = "rhel9"

  validation {
    condition     = contains(["rhel9", "rhel8", "rocky9", "centos-stream9"], var.os)
    error_message = "os must be one of: rhel9, rhel8, rocky9, centos-stream9. For anything else set image."
  }
}

variable "image" {
  description = "An explicit image or image family (\"project/family\"), overriding os."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Boot disk size, GiB."
  type        = number
  default     = 30
}

variable "subnet_cidr" {
  description = "CIDR of the subnet created for these instances."
  type        = string
  default     = "10.43.0.0/20"
}


variable "private_instance_count" {
  description = <<-EOT
    How many of the instances sit in the private subnet, behind the NAT gateway.

    Leave null (the default) to let instance_count and the shared
    private_instances flag decide, which is the common case: all instances in one
    placement.

    Set this - and/or public_instance_count - to mix the two in one stack. When
    either is set, instance_count and private_instances are ignored for this
    stack. For two private and one public:

      private_instance_count = 2
      public_instance_count  = 1
  EOT
  type        = number
  default     = null

  validation {
    condition     = coalesce(var.private_instance_count, 0) >= 0
    error_message = "private_instance_count cannot be negative."
  }
}

variable "public_instance_count" {
  description = <<-EOT
    How many of the instances sit in the public subnet with a public IP. Leave
    null to let instance_count and private_instances decide. See
    private_instance_count.
  EOT
  type        = number
  default     = null

  validation {
    condition     = coalesce(var.public_instance_count, 0) >= 0
    error_message = "public_instance_count cannot be negative."
  }
}

# ---------------------------------------------------------------------------
# The project itself
#
# Terraform can own the project, so a demo environment is created and destroyed
# in one piece, or it can target a project that already exists.
# ---------------------------------------------------------------------------

variable "create_project" {
  description = <<-EOT
    false (default): project_id must already exist, and Terraform only creates
    resources inside it. Destroying leaves the project alone.

    true: Terraform creates and manages the project itself, which also means
    `destroy` deletes it and everything in it - the cleanest possible teardown.
    Needs org_id (or folder_id) and billing_account.

    If the project already exists and you want Terraform to manage it, import it
    once rather than setting this and hoping:

      terraform -chdir=stacks/gcp import 'google_project.this[0]' <project-id>
      terraform -chdir=stacks/gcp import \
        'google_project_service.this["compute.googleapis.com"]' \
        '<project-id>/compute.googleapis.com'

    Without that import, the apply fails with "project already exists" (409),
    because Terraform has no way to adopt a resource it has never seen.

    Note: GCP never releases a project ID. A project destroyed this way cannot be
    recreated under the same name.
  EOT
  type        = bool
  default     = false
}

variable "project_name" {
  description = "Display name for a project Terraform creates. Defaults to project_id."
  type        = string
  default     = null
}

variable "org_id" {
  description = "Organisation to create the project under. One of org_id or folder_id is required when create_project is true."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "Folder to create the project under, instead of directly in the organisation."
  type        = string
  default     = null
}

variable "billing_account" {
  description = <<-EOT
    Billing account to link a newly created project to. Required when
    create_project is true: without billing, the Compute Engine API cannot be
    used and the instances fail even though the project exists.

      gcloud billing accounts list
  EOT
  type        = string
  default     = null
}

variable "project_services" {
  description = "APIs to enable on a project Terraform creates."
  type        = list(string)
  default     = ["compute.googleapis.com"]
}

variable "project_deletion_policy" {
  description = <<-EOT
    What `destroy` does to a Terraform-managed project.

      DELETE   delete it - what makes the teardown clean (the default here)
      PREVENT  refuse to destroy it (the provider's own default)
      ABANDON  remove it from state but leave it in GCP
  EOT
  type        = string
  default     = "DELETE"

  validation {
    condition     = contains(["DELETE", "PREVENT", "ABANDON"], var.project_deletion_policy)
    error_message = "project_deletion_policy must be DELETE, PREVENT or ABANDON."
  }
}
