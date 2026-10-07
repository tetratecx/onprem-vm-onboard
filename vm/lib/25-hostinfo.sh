# Step 2b: install the HostInfo plugin.
#
# The agent asks it for this host's addresses. It reports the private address as
# VPC and, when the instance has one, the public address as INTERNET - which is
# what a workload with connectedOver INTERNET needs, and what the agent's
# built-in "basic" mode cannot provide (a cloud public address is NAT'd, never
# present on a local interface).

step_hostinfo() {
  if [[ "${HOSTINFO_MODE}" != "plugin" ]]; then
    info "HOSTINFO_MODE is \"${HOSTINFO_MODE}\", not installing the HostInfo plugin"
    return 0
  fi

  log "Installing the HostInfo plugin"

  local src; src="$(resolve_path "${HOSTINFO_SOURCE}")"
  [[ -f "${src}" ]] || die "HostInfo plugin not found at ${src}
     It ships in vm/bin/; set HOSTINFO_MODE=\"basic\" to use the agent's built-in
     interface scan instead, which cannot report a public address."

  install -m 0755 "${src}" "${HOSTINFO_PLUGIN_PATH}"
  info "installed ${HOSTINFO_PLUGIN_PATH}"

  # Show what it will tell the agent: the quickest way to spot a metadata
  # service that is blocked, or an instance with no public address when one was
  # expected.
  local detected
  if detected="$("${HOSTINFO_PLUGIN_PATH}" --print 2>/dev/null)"; then
    local line
    while IFS= read -r line; do info "  ${line}"; done <<<"${detected}"
  else
    warn "the plugin could not read any address from the metadata service;"
    warn "the agent will retry, and ${HOSTINFO_PLUGIN_PATH} --print shows why"
  fi

  return 0
}
