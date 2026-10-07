variable "enabled" {
  description = "false renders empty scripts, leaving the instances untouched."
  type        = bool
  default     = true
}

variable "onboarding" {
  description = "The onboarding settings, as passed from the stack. Mirrors vm/vm.env."
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
}
