# Step 5: validate the credential, then enable and (re)start the services.

# Runs the plugin exactly as the agent will, before anything is started, so a
# misconfiguration shows up here as a readable report instead of as an endless
# onboarding retry loop in the agent log.
#
# 'check' performs the full chain: resolve Keycloak, request a token with the
# client_credentials grant, verify 'iss', verify the signature against the JWKS
# document, and verify that 'aud' contains the Workload Onboarding Plane UID.
step_check() {
  log "Checking the credential against Keycloak"

  if [[ -z "${ONBOARDING_PLANE_UID:-}" ]]; then
    warn "ONBOARDING_PLANE_UID is not set, skipping the check"
    return 0
  fi

  local user; user="$(agent_user)"
  local -a env_args
  mapfile -t env_args < <(plugin_env)

  # run it as the agent user: this also proves the secret file is readable by
  # the account the agent actually runs as
  if sudo -u "${user}" env "${env_args[@]}" \
      "${PLUGIN_PATH}" check --audience "${ONBOARDING_PLANE_UID}"; then
    info "the plugin can obtain a valid credential"
  else
    warn "the plugin cannot obtain a usable credential yet - see the report above."
    warn "A failing 'aud' check means the Keycloak client has no Audience mapper for"
    warn "  ${ONBOARDING_PLANE_UID}"
    warn "Add one from the cluster side: k8s/keycloak/add-audience.sh '${ONBOARDING_PLANE_UID}'"
    CHECK_FAILED=1
  fi

  return 0
}

step_services() {
  log "Starting the services"

  systemctl daemon-reload

  systemctl enable onboarding-agent >/dev/null 2>&1 || true
  if [[ -n "${AGENT_CONFIG_CHANGED:-}" ]] || ! systemctl is-active --quiet onboarding-agent; then
    # a credential cached under the previous configuration would be reused
    rm -f "${CREDENTIAL_CACHE_FILE}"
    systemctl restart onboarding-agent
    info "onboarding-agent (re)started"
  else
    info "onboarding-agent already running with this configuration"
  fi

  if [[ "${INSTALL_OBSTESTER}" == "true" ]]; then
    systemctl enable obstester >/dev/null 2>&1 || true
    if [[ -n "${OBSTESTER_CHANGED:-}" ]] || ! systemctl is-active --quiet obstester; then
      systemctl restart obstester
      info "obstester (re)started"
    else
      info "obstester already running"
    fi
  fi
}
