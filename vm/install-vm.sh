#!/usr/bin/env bash
#
# Turns a bare CentOS / RHEL / Rocky / Alma / Ubuntu VM into a mesh workload that
# onboards into TSB with a Keycloak-issued JWT.
#
#   1. installs the Onboarding Agent and the Istio sidecar from the vmgateway
#   2. installs the External JWT Credential Plugin and the Keycloak client secret
#   3. renders /etc/onboarding-agent/{agent,onboarding}.config.yaml
#   4. installs the obs-tester demo service (optional)
#   5. verifies the credential against Keycloak, then starts the services
#
# Run it on the VM, as root:
#
#   sudo ./install-vm.sh                        # uses vm.env next to this script
#   sudo ./install-vm.sh vm.env.local           # or your own copy
#   sudo ./install-vm.sh --check-only           # only verify the token, change nothing
#   sudo KEYCLOAK_CLIENT_SECRET='...' ./install-vm.sh
#
# Safe to re-run: files are rewritten only when their content changes, and the
# services restart only when something changed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- fixed paths on the VM ----------------------------------------------------
PLUGIN_PATH="/usr/local/bin/onboarding-agent-ext-jwt-credential-plugin"
CLIENT_SECRET_FILE="/etc/onboarding-agent/client-secret"
CREDENTIAL_CACHE_FILE="/var/lib/onboarding-agent/ext-jwt-credential.cache"
OBSTESTER_PATH="/usr/local/bin/ots"
HOSTINFO_PLUGIN_PATH="/usr/local/bin/onboarding-agent-hostinfo-plugin"
export PLUGIN_PATH CLIENT_SECRET_FILE CREDENTIAL_CACHE_FILE OBSTESTER_PATH \
       HOSTINFO_PLUGIN_PATH

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
for f in "${SCRIPT_DIR}"/lib/[0-9]*.sh; do source "${f}"; done

# --- arguments ----------------------------------------------------------------
ENV_FILE=""
CHECK_ONLY=""
for arg in "$@"; do
  case "${arg}" in
    --check-only) CHECK_ONLY=1 ;;
    -h|--help)    sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)           die "unknown option: ${arg}" ;;
    *)            ENV_FILE="${arg}" ;;
  esac
done
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/vm.env}"
[[ -f "${ENV_FILE}" ]] || die "env file not found: ${ENV_FILE}"

# --- preflight ----------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0 $*"
[[ "$(uname -s)" == "Linux" ]] || die "this script runs on the Linux VM, not on your laptop"

# A secret from the environment wins over the env file, so it never has to be
# written to a file that lives in git.
SECRET_FROM_ENV="${KEYCLOAK_CLIENT_SECRET:-}"
# shellcheck disable=SC1090
source "${ENV_FILE}"
[[ -n "${SECRET_FROM_ENV}" ]] && KEYCLOAK_CLIENT_SECRET="${SECRET_FROM_ENV}"

require VM_ENDPOINT WORKLOAD_GROUP_NAMESPACE WORKLOAD_GROUP_NAME CONNECTED_OVER \
        KEYCLOAK_REALM_URL KEYCLOAK_CLIENT_ID

HOSTINFO_MODE="${HOSTINFO_MODE:-plugin}"
HOSTINFO_SOURCE="${HOSTINFO_SOURCE:-bin/hostinfo-plugin.sh}"
ONBOARDING_TLS_INSECURE="${ONBOARDING_TLS_INSECURE:-true}"
INSTALL_OBSTESTER="${INSTALL_OBSTESTER:-false}"
PLUGIN_SOURCE="${PLUGIN_SOURCE:-bin/onboarding-agent-ext-jwt-credential-plugin}"
OBSTESTER_SOURCE="${OBSTESTER_SOURCE:-bin/ots-linux-x86_64}"
# a trailing slash here would stop the issuer matching the token's 'iss'
KEYCLOAK_REALM_URL="${KEYCLOAK_REALM_URL%/}"

# CONNECTED_OVER decides which of this host's addresses ends up in the
# WorkloadEntry, so it has to match what the cluster can actually route to.
# "auto" asks the HostInfo plugin: an instance with a public address is reachable
# over the internet, one without is not. That keeps a public and a private
# instance from both claiming VPC just because they share an env file.
if [[ "${CONNECTED_OVER}" == "auto" ]]; then
  hostinfo_src="$(resolve_path "${HOSTINFO_SOURCE}")"
  # Run through bash rather than executing it: this happens before the plugin is
  # installed, and scp does not reliably preserve the executable bit.
  if [[ -f "${hostinfo_src}" ]] && detected="$(bash "${hostinfo_src}" --type 2>/dev/null)"; then
    CONNECTED_OVER="${detected}"
    info "CONNECTED_OVER=auto resolved to ${CONNECTED_OVER}"
  else
    CONNECTED_OVER="VPC"
    warn "CONNECTED_OVER=auto could not be resolved, falling back to VPC"
  fi
fi
case "${CONNECTED_OVER}" in
  INTERNET|VPC) ;;
  *) die "CONNECTED_OVER must be INTERNET, VPC or auto, not \"${CONNECTED_OVER}\"" ;;
esac

export VM_ENDPOINT ONBOARDING_TLS_INSECURE WORKLOAD_GROUP_NAMESPACE WORKLOAD_GROUP_NAME \
       CONNECTED_OVER KEYCLOAK_REALM_URL KEYCLOAK_CLIENT_ID \
       HOSTINFO_MODE HOSTINFO_SOURCE \
       OBSTESTER_SVCNAME="${OBSTESTER_SVCNAME:-payments}"

# --- package format, manager and architecture ---------------------------------
# The vmgateway publishes packages as /install/{deb,rpm}/{amd64,arm64}/<pkg>.<fmt>
if   hash apt-get 2>/dev/null; then PKG_FORMAT=deb; PKG_MANAGER=apt
elif hash dnf     2>/dev/null; then PKG_FORMAT=rpm; PKG_MANAGER=dnf
elif hash yum     2>/dev/null; then PKG_FORMAT=rpm; PKG_MANAGER=yum
elif hash zypper  2>/dev/null; then PKG_FORMAT=rpm; PKG_MANAGER=zypper
elif hash dpkg    2>/dev/null; then PKG_FORMAT=deb; PKG_MANAGER=apt
elif hash rpm     2>/dev/null; then PKG_FORMAT=rpm; PKG_MANAGER=rpm
else die "no supported package manager found (apt-get, dnf, yum or zypper)"
fi

case "$(uname -m)" in
  x86_64|amd64)  PKG_ARCH=amd64 ;;
  aarch64|arm64) PKG_ARCH=arm64 ;;
  *) die "unsupported architecture $(uname -m): the vmgateway publishes amd64 and arm64 only" ;;
esac

for tool in curl envsubst setcap systemctl; do
  hash "${tool}" 2>/dev/null || die "${tool} missing - install it first:
     RHEL/CentOS/Rocky/Alma: ${PKG_MANAGER} install -y curl gettext libcap
     Ubuntu/Debian:          apt-get install -y curl gettext-base libcap2-bin"
done

log "Onboarding ${WORKLOAD_GROUP_NAMESPACE}/${WORKLOAD_GROUP_NAME} through ${VM_ENDPOINT}"
info "env file:        ${ENV_FILE}"
info "os:              $( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}") || uname -sr) (${PKG_FORMAT}, ${PKG_ARCH})"
info "keycloak client: ${KEYCLOAK_CLIENT_ID} at ${KEYCLOAK_REALM_URL}"
info "plane uid:       ${ONBOARDING_PLANE_UID:-<not set, the check will be skipped>}"
info "connected over:  ${CONNECTED_OVER} (hostinfo: ${HOSTINFO_MODE})"

if [[ -n "${CHECK_ONLY}" ]]; then
  [[ -x "${PLUGIN_PATH}" ]] || die "${PLUGIN_PATH} is not installed yet; run without --check-only first"
  step_check
  [[ -z "${CHECK_FAILED:-}" ]] || exit 1
  exit 0
fi

step_packages
step_plugin
step_hostinfo
step_config
step_obstester
step_check
step_services

log "Done"
cat <<EOF
    Watch the agent onboard:
      journalctl -u onboarding-agent -f

    Inspect the token it presents:
      ${SCRIPT_DIR}/get-token.sh --decode

    Confirm the WorkloadEntry was created (from a machine with kubectl):
      kubectl -n ${WORKLOAD_GROUP_NAMESPACE} get workloadentry

EOF
[[ -z "${CHECK_FAILED:-}" ]] || warn "the credential check did not pass - the agent will retry until it does"
