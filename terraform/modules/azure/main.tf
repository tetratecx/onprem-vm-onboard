# Azure: a resource group with one VNet and a single VM subnet holding every
# instance. The public ones get their own public IP; the private ones get none
# and reach the internet through the NAT gateway attached to the subnet.
#
# There is no separate bastion: when private instances need a way in, one of the
# public mesh VMs is designated the jump host by the stack (var.jump_host_key).

locals {
  name = var.name_prefix

  # A single subnet holds every instance; the public ones get their own public
  # IP and the private ones use the NAT gateway attached to it.
  subnet_cidr = cidrsubnet(var.vnet_cidr, 8, 0)

  # Only the RedHat-published RHEL images are listed: they are plain
  # pay-as-you-go images that need no marketplace plan acceptance, so a VM comes
  # up without any extra subscription step. Rocky, Alma and CentOS Stream on
  # Azure come from marketplace publishers whose terms must be accepted first
  # and which then also need a `plan` block - pass those through var.image and
  # see the README.
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

  # Only the public instances get a public IP resource.
  public_instance_keys = [for k, v in local.instances : k if !v.private]

  any_private = var.private_instance_count > 0
  any_public  = var.public_instance_count > 0

  images = {
    rhel9 = { publisher = "RedHat", offer = "RHEL", sku = "9-lvm-gen2", version = "latest" }
    rhel8 = { publisher = "RedHat", offer = "RHEL", sku = "8-lvm-gen2", version = "latest" }
  }
  image = coalesce(var.image, local.images[var.os])
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = var.tags
}

# --- network ----------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "${local.name}-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_subnet" "vm" {
  name                 = "${local.name}-vm"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnet_cidr]
}

# --- NAT gateway ------------------------------------------------------------
# Only when the instances are private. Azure's default outbound access is being
# retired, so an explicit NAT gateway is the supported way to give a private
# subnet egress - which the VMs need for the vmgateway and Keycloak.

resource "azurerm_public_ip" "nat" {
  count = local.any_private ? 1 : 0

  name                = "${local.name}-nat"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  count = local.any_private ? 1 : 0

  name                = "${local.name}-nat"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = local.any_private ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "vm" {
  count = local.any_private ? 1 : 0

  subnet_id      = azurerm_subnet.vm.id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}

# --- security groups --------------------------------------------------------

resource "azurerm_network_security_group" "vm" {
  name                = "${local.name}-vm"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# One SSH rule for the whole subnet, sourced from the allowed CIDRs.
resource "azurerm_network_security_rule" "vm_ssh" {
  name                        = "ssh"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  destination_address_prefix  = "*"

  # For a public instance this is the way in - including the one acting as jump
  # host. For a private instance the rule is unreachable from those CIDRs, so it
  # costs nothing to keep; and with no jump host it is what lets an existing VPN
  # or ExpressRoute range reach them.
  source_address_prefixes = var.ssh_allowed_cidrs
}

# How the TSB cluster reaches the sidecar and the application.
resource "azurerm_network_security_rule" "vm_mesh" {
  count = length(var.mesh_allowed_cidrs) > 0 ? 1 : 0

  name                        = "mesh"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_address_prefix  = "*"
  source_address_prefixes     = var.mesh_allowed_cidrs
  destination_port_ranges     = [for p in var.mesh_ports : tostring(p)]
}

resource "azurerm_network_security_rule" "vm_internal" {
  # Also what lets the public jump host reach SSH on the private instances:
  # they share this subnet and NSG, so no jump-host-specific rule is needed.
  name                        = "internal"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.vnet_cidr
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# --- instances --------------------------------------------------------------

resource "azurerm_public_ip" "vm" {
  for_each = toset(local.public_instance_keys)

  name                = "${local.name}-${each.key}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "vm" {
  for_each = local.instances

  name                = "${local.name}-${each.key}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    # No public IP for a private instance: it reaches the internet through the
    # NAT gateway attached to the subnet. Note that the NAT gateway only applies
    # to instances without one, so a mixed stack works as expected - the public
    # instances use their own address, the private ones the gateway.
    public_ip_address_id = each.value.private ? null : azurerm_public_ip.vm[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each = local.instances

  name                = "${local.name}-${each.key}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.vm[each.key].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.root_volume_size
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }

  # Azure runs custom_data through cloud-init on the RHEL images. The two scripts
  # differ only in CONNECTED_OVER, which must match where the instance sits.
  custom_data = (each.value.private
    ? (var.user_data.private != "" ? base64encode(var.user_data.private) : null)
    : (var.user_data.public != "" ? base64encode(var.user_data.public) : null)
  )

  tags = merge(var.tags, {
    role      = "mesh-vm"
    placement = each.value.private ? "private" : "public"
  })

  depends_on = [
    azurerm_subnet_nat_gateway_association.vm,
    azurerm_subnet_network_security_group_association.vm,
  ]
}

