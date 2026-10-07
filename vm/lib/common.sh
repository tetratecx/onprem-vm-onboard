# Shared helpers for the install-vm.sh steps. Sourced, never executed.

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# require <var> [<var>...] - fail unless every named variable is set
require() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "${name} is not set in the env file"
  done
}

# write_template <template> <destination> [mode]
# Renders with envsubst and installs only when the content changed, so re-runs
# are quiet and the services are restarted only when something really moved.
# Returns 0 when the file changed, 1 when it was already correct.
write_template() {
  local src="$1" dst="$2" mode="${3:-0644}" tmp
  tmp="$(mktemp)"
  envsubst <"${src}" >"${tmp}"
  if [[ -f "${dst}" ]] && cmp -s "${tmp}" "${dst}"; then
    info "${dst} unchanged"
    rm -f "${tmp}"
    return 1
  fi
  install -m "${mode}" "${tmp}" "${dst}"
  rm -f "${tmp}"
  info "wrote ${dst}"
  return 0
}

# agent_user - the user the onboarding agent runs as, or root if the package
# created no dedicated user
agent_user() {
  if id -u onboarding-agent >/dev/null 2>&1; then echo onboarding-agent; else echo root; fi
}

# resolve_path <path> - absolute paths as-is, relative ones next to the script
resolve_path() {
  [[ "$1" == /* ]] && { printf '%s\n' "$1"; return; }
  printf '%s\n' "${SCRIPT_DIR}/$1"
}

# plugin_env - the environment the plugin runs with, exactly as the rendered
# agent.config.yaml sets it. Used by the pre-flight check and by get-token.sh,
# so what is verified is what the agent will actually do.
plugin_env() {
  printf '%s\n' \
    "EXT_JWT_ISSUER=${KEYCLOAK_REALM_URL}" \
    "EXT_JWT_TOKEN_ENDPOINT=${KEYCLOAK_REALM_URL}/protocol/openid-connect/token" \
    "EXT_JWT_JWKS_URI=${KEYCLOAK_REALM_URL}/protocol/openid-connect/certs" \
    "EXT_JWT_GRANT_TYPE=client_credentials" \
    "EXT_JWT_CLIENT_ID=${KEYCLOAK_CLIENT_ID}" \
    "EXT_JWT_CLIENT_AUTH_METHOD=client_secret_post" \
    "EXT_JWT_CLIENT_SECRET_FILE=${CLIENT_SECRET_FILE}" \
    "EXT_JWT_AUDIENCE_MODE=param" \
    "EXT_JWT_VERIFY_TOKEN=true" \
    "EXT_JWT_REQUIRE_AUDIENCE=true" \
    "EXT_JWT_LOG_LEVEL=${EXT_JWT_LOG_LEVEL:-info}"
  [[ -n "${KEYCLOAK_CA_FILE:-}" ]] && printf 'EXT_JWT_CA_FILE=%s\n' "${KEYCLOAK_CA_FILE}"
  return 0
}
