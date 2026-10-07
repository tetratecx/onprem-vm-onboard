output "user_data" {
  description = <<-EOT
    The cloud-init script per placement: user_data["private"] and
    user_data["public"]. They differ only in the CONNECTED_OVER value written
    into vm.env. Empty strings when disabled.
  EOT
  value       = local.user_data
}

output "vm_env" {
  description = "The rendered vm.env per placement, for inspection."
  value       = local.vm_env
}

output "plane_uid" {
  description = "The onboarding plane UID the instances expect in the token's 'aud'."
  value       = local.plane_uid
}

output "connected_over" {
  description = "The CONNECTED_OVER value chosen for each placement."
  value       = local.connected_over
}
