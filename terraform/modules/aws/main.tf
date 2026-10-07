# AWS: a self-contained VPC with a public subnet, and - when the instances are
# private - a private subnet whose egress goes through a NAT gateway.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = var.name_prefix

  # Two AZs by default, so instances spread and the NAT gateway has a home.
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)

  # Non-overlapping /24s out of the VPC CIDR.
  public_subnet_cidrs  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 100)]

  # One entry per instance, keyed by a stable name. Using for_each over this map
  # rather than count means changing one of the counts adds or removes only that
  # instance, instead of renumbering - and reshuffling - the others.
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

  # Owners and name patterns of the stock cloud images.
  images = {
    rhel9          = { owner = "309956199498", name = "RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3" }
    rhel8          = { owner = "309956199498", name = "RHEL-8.*_HVM-*-x86_64-*-Hourly2-GP2" }
    rocky9         = { owner = "792107900819", name = "Rocky-9-EC2-Base-9.*-x86_64" }
    centos-stream9 = { owner = "125523088429", name = "CentOS-Stream-ec2-9-*.x86_64" }
  }
  image = local.images[var.os]
}

# --- image ------------------------------------------------------------------

data "aws_ami" "vm" {
  count = var.ami_id == null ? 1 : 0

  most_recent = true
  owners      = [local.image.owner]

  filter {
    name   = "name"
    values = [local.image.name]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = coalesce(var.ami_id, try(data.aws_ami.vm[0].id, null))
}

# --- network ----------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = local.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = local.name })
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, { Name = "${local.name}-public-${local.azs[count.index]}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${local.name}-public" })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- private subnets and the NAT gateway ------------------------------------
# Only built when the instances are private. The NAT gateway is what lets them
# download the onboarding packages from the vmgateway and reach Keycloak,
# without being reachable from the internet themselves.

resource "aws_subnet" "private" {
  count = local.any_private ? length(local.azs) : 0

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, { Name = "${local.name}-private-${local.azs[count.index]}" })
}

resource "aws_eip" "nat" {
  count = local.any_private ? 1 : 0

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${local.name}-nat" })

  depends_on = [aws_internet_gateway.this]
}

# One NAT gateway, in the first public subnet. Enough for onboarding traffic; for
# zonal resilience, create one per AZ and a route table per private subnet.
resource "aws_nat_gateway" "this" {
  count = local.any_private ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.tags, { Name = local.name })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  count = local.any_private ? 1 : 0

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }

  tags = merge(var.tags, { Name = "${local.name}-private" })
}

resource "aws_route_table_association" "private" {
  count = local.any_private ? length(aws_subnet.private) : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# --- security groups --------------------------------------------------------

resource "aws_security_group" "vm" {
  name        = "${local.name}-vm"
  description = "TSB mesh VM: SSH in, mesh ports in, everything out"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${local.name}-vm" })

  lifecycle {
    create_before_destroy = true
  }
}

# SSH from the allowed CIDRs, to every instance in the group.
#
# For a public instance this is the way in - including the one acting as jump
# host. For a private instance the rule is simply unreachable from those CIDRs,
# so it costs nothing to keep; and when there is no jump host at all it is
# exactly what lets an existing VPN or Direct Connect reach them.
resource "aws_security_group_rule" "vm_ssh" {
  type              = "ingress"
  description       = "SSH from the allowed CIDRs"
  security_group_id = aws_security_group.vm.id
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.ssh_allowed_cidrs
}


# How the TSB cluster reaches the sidecar and the application.
resource "aws_security_group_rule" "vm_mesh" {
  count = length(var.mesh_allowed_cidrs) > 0 ? length(var.mesh_ports) : 0

  type              = "ingress"
  description       = "mesh/app port ${var.mesh_ports[count.index]}"
  security_group_id = aws_security_group.vm.id
  from_port         = var.mesh_ports[count.index]
  to_port           = var.mesh_ports[count.index]
  protocol          = "tcp"
  cidr_blocks       = var.mesh_allowed_cidrs
}

# Instances talk to each other freely inside the VPC. This is also what lets
# the public jump host reach SSH on the private instances: they all share this
# one security group, so no jump-host-specific rule is needed.
resource "aws_security_group_rule" "vm_self" {
  type              = "ingress"
  description       = "within the VPC"
  security_group_id = aws_security_group.vm.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.vpc_cidr]
}

# Outbound is wide open: the agent needs the vmgateway on 443 and Keycloak on
# 443, and the package install may pull from the distro mirrors.
resource "aws_security_group_rule" "vm_egress" {
  type              = "egress"
  description       = "all outbound (vmgateway, Keycloak, package mirrors)"
  security_group_id = aws_security_group.vm.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

# --- instances --------------------------------------------------------------

resource "aws_key_pair" "this" {
  key_name   = "${local.name}-key"
  public_key = var.ssh_public_key
  tags       = var.tags
}

resource "aws_instance" "vm" {
  # Keyed by "private-N" / "public-N", so each instance has a stable address in
  # state regardless of how the counts change.
  for_each = local.instances

  ami                    = local.ami_id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.vm.id]
  key_name               = aws_key_pair.this.key_name

  # Private instances go in the private subnets and reach the internet through
  # the NAT gateway; public ones go in the public subnets with their own address.
  # Each group is spread over the AZs independently.
  subnet_id = (each.value.private
    ? aws_subnet.private[each.value.ordinal % length(aws_subnet.private)].id
    : aws_subnet.public[each.value.ordinal % length(aws_subnet.public)].id
  )

  associate_public_ip_address = !each.value.private

  # The two scripts differ only in CONNECTED_OVER, which must match where the
  # instance actually sits.
  user_data = each.value.private ? (
    var.user_data.private != "" ? var.user_data.private : null
    ) : (
    var.user_data.public != "" ? var.user_data.public : null
  )

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
    # The root volume is a separate EBS resource and is not covered by the
    # instance's own tags, so it is tagged explicitly - an untagged volume would
    # trip a tag-enforcement policy.
    tags = merge(var.tags, { Name = "${local.name}-${each.key}-root" })
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  tags = merge(var.tags, {
    Name      = "${local.name}-${each.key}"
    role      = "mesh-vm"
    placement = each.value.private ? "private" : "public"
  })

  depends_on = [aws_route_table_association.private, aws_route_table_association.public]
}


locals {
  # The login account baked into the stock images.
  ssh_users = {
    rhel9          = "ec2-user"
    rhel8          = "ec2-user"
    rocky9         = "rocky"
    centos-stream9 = "ec2-user"
  }
  ssh_user = local.ssh_users[var.os]
}
