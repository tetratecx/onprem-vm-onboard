variable "name_prefix" { type = string }
variable "tags" { type = map(string) }

# Placement is per instance now: this many private, this many public. Either can
# be 0. The stack derives them from instance_count + private_instances, or from
# the explicit split.
variable "private_instance_count" { type = number }
variable "public_instance_count" { type = number }
variable "instance_type" { type = string }
variable "availability_zones" { type = list(string) }
variable "os" { type = string }
# Explicit default: the root module passes null to mean "pick the stock image",
# and a variable with no default rejects null.
variable "ami_id" {
  type    = string
  default = null
}
variable "root_volume_size" { type = number }
variable "vpc_cidr" { type = string }

# Which instance doubles as the SSH jump host for the private ones, e.g.
# "public-1", or null when private instances are reached some other way. The
# jump host is an ordinary mesh VM from local.instances, not a separate bastion.
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
