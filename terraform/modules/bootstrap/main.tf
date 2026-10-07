# Renders the cloud-init script and the vm.env it writes.
#
# Both placements are rendered, because CONNECTED_OVER differs between them: a
# private instance is reachable from the cluster over the VPC, a public one over
# the internet, and that decides which address ends up in the WorkloadEntry. A
# stack with instances in both subnets uses both scripts.

locals {
  placements = ["private", "public"]

  # The plane UID defaults to the endpoint URL, exactly as
  # k8s/02-control-plane-patch.yaml derives it.
  plane_uid = coalesce(
    var.onboarding.onboarding_plane_uid,
    "https://${var.onboarding.vm_endpoint}",
  )

  # An explicit connected_over always wins; otherwise it follows the placement.
  connected_over = {
    for p in local.placements : p => coalesce(
      var.onboarding.connected_over,
      p == "private" ? "VPC" : "INTERNET",
    )
  }

  # Names the demo app reaches through the sidecar's egress listeners.
  obstester_hosts = var.onboarding.install_obstester ? "zipkin.istio-system accounting.payments" : ""

  # The same keys vm/vm.env has, so vm/install-vm.sh can use the file as-is.
  # KEYCLOAK_CLIENT_SECRET is deliberately empty: a secret here would be stored
  # in clear text in the Terraform state.
  vm_env = {
    for p in local.placements : p => join("\n", [
      "# Written by Terraform on first boot. Same keys as vm/vm.env.",
      "# KEYCLOAK_CLIENT_SECRET is intentionally empty: pass it at install time with",
      "#   KEYCLOAK_CLIENT_SECRET='...' ./push-to-vm.sh <user>@<host>",
      "VM_ENDPOINT=\"${var.onboarding.vm_endpoint}\"",
      "ONBOARDING_TLS_INSECURE=\"${var.onboarding.onboarding_tls_insecure}\"",
      "ONBOARDING_PLANE_UID=\"${local.plane_uid}\"",
      "WORKLOAD_GROUP_NAMESPACE=\"${var.onboarding.workload_group_namespace}\"",
      "WORKLOAD_GROUP_NAME=\"${var.onboarding.workload_group_name}\"",
      "CONNECTED_OVER=\"${local.connected_over[p]}\"",
      "KEYCLOAK_REALM_URL=\"${var.onboarding.keycloak_realm_url}\"",
      "KEYCLOAK_CLIENT_ID=\"${var.onboarding.keycloak_client_id}\"",
      "KEYCLOAK_CLIENT_SECRET=\"\"",
      "KEYCLOAK_CA_FILE=\"\"",
      "PLUGIN_SOURCE=\"bin/onboarding-agent-ext-jwt-credential-plugin\"",
      "# The HostInfo plugin reports this host's public address as INTERNET,",
      "# which the agent's built-in interface scan cannot do.",
      "HOSTINFO_MODE=\"plugin\"",
      "HOSTINFO_SOURCE=\"bin/hostinfo-plugin.sh\"",
      "INSTALL_OBSTESTER=\"${var.onboarding.install_obstester}\"",
      "OBSTESTER_SOURCE=\"bin/ots-linux-x86_64\"",
      "OBSTESTER_SVCNAME=\"${var.onboarding.workload_group_namespace}\"",
      "OBSTESTER_HOSTS=\"${local.obstester_hosts}\"",
    ])
  }

  user_data = {
    for p in local.placements : p => (
      var.enabled ? templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
        vm_env          = local.vm_env[p]
        obstester_hosts = local.obstester_hosts
      }) : ""
    )
  }
}
