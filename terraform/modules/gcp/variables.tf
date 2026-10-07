variable "name_prefix" { type = string }
variable "labels" { type = map(string) }

variable "project_id" { type = string }
variable "region" { type = string }
variable "zone" { type = string }

# Placement is per instance now: this many private, this many public.
variable "private_instance_count" { type = number }
variable "public_instance_count" { type = number }
variable "machine_type" { type = string }
variable "os" { type = string }
variable "root_volume_size" { type = number }
variable "subnet_cidr" { type = string }

# Explicit default: the root module passes null to mean "pick the stock image".
variable "image" {
  type    = string
  default = null
}

# Which instance doubles as the SSH jump host for the private ones, e.g.
# "public-1", or null when private instances are reached some other way. The
# jump host is an ordinary mesh VM, not a separate bastion.
variable "jump_host_key" {
  type    = string
  default = null
}

variable "ssh_public_key" { type = string }
variable "ssh_allowed_cidrs" { type = list(string) }
variable "mesh_allowed_cidrs" { type = list(string) }
variable "mesh_ports" { type = list(number) }

# One script per placement: they differ in the CONNECTED_OVER written to vm.env.
variable "user_data" {
  type = object({
    private = string
    public  = string
  })
}
