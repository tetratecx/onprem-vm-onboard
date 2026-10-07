# Step 3: render the two agent configuration files.
#
#   agent.config.yaml       how the agent obtains a credential (the plugin)
#   onboarding.config.yaml  where it onboards and which WorkloadGroup it joins

step_config() {
  log "Configuring the Onboarding Agent"

  install -d -m 0755 /etc/onboarding-agent

  # Optional CA bundle for the Keycloak TLS connection. With a publicly trusted
  # certificate (Let's Encrypt and the like) this is not needed; with a
  # corporate CA, set KEYCLOAK_CA_FILE in the env file.
  if [[ -n "${KEYCLOAK_CA_FILE:-}" ]]; then
    CA_FILE_ENV="        - name: EXT_JWT_CA_FILE
          value: ${KEYCLOAK_CA_FILE}"
  else
    CA_FILE_ENV="        # KEYCLOAK_CA_FILE is not set: the system trust store is used for the
        # TLS connection to Keycloak. Set it if Keycloak uses a corporate CA."
  fi
  export CA_FILE_ENV

  # The hostinfo stanza, from HOSTINFO_MODE. Indented to sit under host.custom.
  case "${HOSTINFO_MODE}" in
    plugin)
      HOSTINFO_STANZA="    hostinfo:
      plugin:
        name: hostinfo
        path: ${HOSTINFO_PLUGIN_PATH}"
      ;;
    basic)
      # The agent's built-in interface scan. Reports only private addresses, so
      # a workload with connectedOver INTERNET will advertise the wrong one.
      HOSTINFO_STANZA="    hostinfo:
      basic:
        networkInterfaces:
          include:
          - ^(eth|ens|enp|eno|en)[0-9a-z]*$
          exclude:
          - ^(docker|veth|br-|cni|flannel|virbr)"
      ;;
    default)
      HOSTINFO_STANZA="    # HOSTINFO_MODE=default: no hostinfo stanza, so the agent decides for itself."
      ;;
    *)
      die "HOSTINFO_MODE must be \"plugin\", \"basic\" or \"default\", not \"${HOSTINFO_MODE}\""
      ;;
  esac
  export HOSTINFO_STANZA

  write_template "${SCRIPT_DIR}/templates/agent.config.yaml.tmpl" \
    /etc/onboarding-agent/agent.config.yaml 0644 && AGENT_CONFIG_CHANGED=1
  write_template "${SCRIPT_DIR}/templates/onboarding.config.yaml.tmpl" \
    /etc/onboarding-agent/onboarding.config.yaml 0644 && AGENT_CONFIG_CHANGED=1

  return 0
}
