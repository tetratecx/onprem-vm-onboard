# No provider requirements at all: this module only renders strings, which is
# what lets every stack share it without dragging in another cloud's provider.
terraform {
  required_version = ">= 1.5.0"
}
