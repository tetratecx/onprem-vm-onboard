# Step 2: install the External JWT Credential Plugin and the Keycloak client
# secret.
#
# The plugin is what makes this a pure OAuth 2.0 flow: the agent asks it for a
# credential, and it does a client_credentials token request against Keycloak.
# There is no wrapper process and no local token endpoint.

step_plugin() {
  log "Installing the External JWT Credential Plugin"

  local src; src="$(resolve_path "${PLUGIN_SOURCE}")"

  if [[ -f "${src}" ]]; then
    install -m 0755 "${src}" "${PLUGIN_PATH}"
    info "installed ${PLUGIN_PATH}"
  elif [[ -x "${PLUGIN_PATH}" ]]; then
    warn "${src} not found, keeping the plugin already installed at ${PLUGIN_PATH}"
  else
    die "plugin binary not found at ${src} and not installed at ${PLUGIN_PATH}
     Copy it to vm/bin/onboarding-agent-ext-jwt-credential-plugin, built for ${PKG_ARCH}."
  fi

  local user; user="$(agent_user)"

  install -d -m 0755 /etc/onboarding-agent
  # the cache holds live tokens: only the agent user may read it
  install -d -o "${user}" -m 0700 /var/lib/onboarding-agent

  if [[ -n "${KEYCLOAK_CLIENT_SECRET:-}" ]]; then
    # printf, not echo: a trailing newline would become part of the secret and
    # Keycloak would answer 'invalid_client'
    local tmp; tmp="$(mktemp)"
    printf '%s' "${KEYCLOAK_CLIENT_SECRET}" >"${tmp}"
    install -o "${user}" -m 0600 "${tmp}" "${CLIENT_SECRET_FILE}"
    rm -f "${tmp}"
    info "wrote ${CLIENT_SECRET_FILE} (owner ${user}, mode 0600)"
  elif [[ -f "${CLIENT_SECRET_FILE}" ]]; then
    warn "KEYCLOAK_CLIENT_SECRET is empty, keeping the existing ${CLIENT_SECRET_FILE}"
  else
    die "KEYCLOAK_CLIENT_SECRET is not set and ${CLIENT_SECRET_FILE} does not exist"
  fi

  if [[ -n "${KEYCLOAK_CA_FILE:-}" ]]; then
    [[ -f "${KEYCLOAK_CA_FILE}" ]] \
      || die "KEYCLOAK_CA_FILE is set but ${KEYCLOAK_CA_FILE} does not exist on this VM"
    info "the plugin will trust the CA bundle at ${KEYCLOAK_CA_FILE}"
  fi
}
