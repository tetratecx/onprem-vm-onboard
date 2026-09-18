#!/usr/bin/env bash
#
# Configures an MS VM to onboard with a Hydra-issued JWT, through the External
# JWT Credential Plugin:
#
#   Onboarding Agent -> ext-jwt-credential plugin -> hydra-token-shim (127.0.0.1)
#                                                 -> hydra ... service token <audience>
#
# Steps:
#   1. install the Onboarding Agent and the Istio sidecar from the vmgateway
#   2. install the plugin and the token shim (+ its systemd unit)
#   3. render /etc/onboarding-agent/{agent,onboarding}.config.yaml
#   4. start the shim, verify a token end to end, start the agent
#
# Run on the VM, as root:
#
#   sudo ./install-ms-vm.sh [env file] [--check-only]
#
# Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLUGIN_PATH="/usr/local/bin/onboarding-agent-ext-jwt-credential-plugin"
SHIM_PATH="/usr/local/bin/hydra-token-shim.py"
CREDENTIAL_CACHE_FILE="/var/lib/onboarding-agent/ext-jwt-credential.cache"
export PLUGIN_PATH SHIM_PATH CREDENTIAL_CACHE_FILE

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

ENV_FILE=""; CHECK_ONLY=""
for arg in "$@"; do
  case "${arg}" in
    --check-only) CHECK_ONLY=1 ;;
    -h|--help)    sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)           die "unknown option: ${arg}" ;;
    *)            ENV_FILE="${arg}" ;;
  esac
done
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/ms-vm.env}"
[[ -f "${ENV_FILE}" ]] || die "env file not found: ${ENV_FILE}"

[[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0 $*"
[[ "$(uname -s)" == "Linux" ]] || die "this runs on the VM, not on your laptop"

# shellcheck disable=SC1090
source "${ENV_FILE}"
: "${VM_ENDPOINT:?not set in ${ENV_FILE}}"
: "${ONBOARDING_PLANE_UID:?not set in ${ENV_FILE}}"
: "${HYDRA_ISSUER:?not set in ${ENV_FILE}}"
: "${HYDRA_USER:?not set in ${ENV_FILE}}"
ONBOARDING_TLS_INSECURE="${ONBOARDING_TLS_INSECURE:-true}"
SHIM_LISTEN_ADDRESS="${SHIM_LISTEN_ADDRESS:-127.0.0.1}"
SHIM_LISTEN_PORT="${SHIM_LISTEN_PORT:-9099}"
SHIM_SECRET_FILE="${SHIM_SECRET_FILE:-/etc/onboarding-agent/shim-secret}"
HYDRA_TIMEOUT="${HYDRA_TIMEOUT:-60}"

export VM_ENDPOINT ONBOARDING_TLS_INSECURE WORKLOAD_GROUP_NAMESPACE WORKLOAD_GROUP_NAME \
       CONNECTED_OVER HYDRA_ISSUER HYDRA_COMMAND HYDRA_USER HYDRA_TIMEOUT \
       SHIM_LISTEN_ADDRESS SHIM_LISTEN_PORT SHIM_SECRET_FILE

id -u "${HYDRA_USER}" >/dev/null 2>&1 || die "HYDRA_USER '${HYDRA_USER}' does not exist on this VM"

if   command -v apt-get >/dev/null; then PKG_FORMAT=deb; PKG_INSTALL="apt-get install -y"
elif command -v dnf     >/dev/null; then PKG_FORMAT=rpm; PKG_INSTALL="dnf install -y"
elif command -v yum     >/dev/null; then PKG_FORMAT=rpm; PKG_INSTALL="yum install -y"
elif command -v zypper  >/dev/null; then PKG_FORMAT=rpm; PKG_INSTALL="zypper --non-interactive install --allow-unsigned-rpm"
else die "no supported package manager (apt-get, dnf, yum, zypper)"
fi
case "$(uname -m)" in
  x86_64|amd64)  PKG_ARCH=amd64 ;;
  aarch64|arm64) PKG_ARCH=arm64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

for tool in curl envsubst python3 systemctl; do
  command -v "${tool}" >/dev/null || die "${tool} missing (install curl, gettext, python3)"
done

# render_template <src> <dst> [mode] - returns 0 when the file changed
render_template() {
  local src="$1" dst="$2" mode="${3:-0644}" tmp; tmp="$(mktemp)"
  envsubst <"${src}" >"${tmp}"
  if [[ -f "${dst}" ]] && cmp -s "${tmp}" "${dst}"; then rm -f "${tmp}"; info "${dst} unchanged"; return 1; fi
  install -m "${mode}" "${tmp}" "${dst}"; rm -f "${tmp}"; info "wrote ${dst}"; return 0
}

agent_user() { id -u onboarding-agent >/dev/null 2>&1 && echo onboarding-agent || echo root; }

# Requests a token through the shim exactly as the plugin does, and prints the
# claims that decide whether onboarding succeeds.
check_token() {
  log "Requesting a token through the shim"
  local secret=""; [[ -f "${SHIM_SECRET_FILE}" ]] && secret="$(cat "${SHIM_SECRET_FILE}")"
  local response
  response="$(curl -s --max-time 120 -X POST \
    "http://${SHIM_LISTEN_ADDRESS}:${SHIM_LISTEN_PORT}/token" \
    -d grant_type=client_credentials \
    -d client_id=onboarding-agent \
    --data-urlencode "client_secret=${secret}" \
    --data-urlencode "audience=${ONBOARDING_PLANE_UID}")" || { warn "the shim did not answer"; return 1; }

  local token; token="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' <<<"${response}" 2>/dev/null || true)"
  if [[ -z "${token}" ]]; then
    warn "no token from the shim: ${response}"
    warn "check the shim log: journalctl -u hydra-token-shim -n 50"
    return 1
  fi

  python3 - "${token}" "${ONBOARDING_PLANE_UID}" "${HYDRA_ISSUER}" <<'PY'
import base64, json, sys, time
token, want_aud, want_iss = sys.argv[1], sys.argv[2], sys.argv[3]
p = token.split(".")[1]; p += "=" * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
aud = c.get("aud"); aud = aud if isinstance(aud, list) else [aud]
print(f"    sub: {c.get('sub')}")
print(f"    iss: {c.get('iss')}")
print(f"    aud: {', '.join(str(a) for a in aud)}")
print(f"    exp: in {int(c.get('exp', 0) - time.time())}s")
ok = True
if c.get("iss") != want_iss:
    print(f"    [fail] 'iss' is {c.get('iss')!r}, the ControlPlane must trust exactly this value"); ok = False
if want_aud not in aud:
    print(f"    [fail] 'aud' does not contain {want_aud!r} - the Workload Onboarding Plane will reject it"); ok = False
print("    [ ok ] the token carries the expected issuer and audience" if ok else "")
sys.exit(0 if ok else 1)
PY
}

log "Onboarding ${WORKLOAD_GROUP_NAMESPACE:-?}/${WORKLOAD_GROUP_NAME:-?} through ${VM_ENDPOINT}"
info "env file:  ${ENV_FILE}"
info "issuer:    ${HYDRA_ISSUER}"
info "audience:  ${ONBOARDING_PLANE_UID}"
info "hydra as:  ${HYDRA_USER}"

if [[ -n "${CHECK_ONLY}" ]]; then
  check_token || exit 1
  exit 0
fi

# --- 1. packages --------------------------------------------------------------
log "Installing the onboarding packages (${PKG_FORMAT}, ${PKG_ARCH})"
if { [[ "${PKG_FORMAT}" == deb ]] && dpkg -s onboarding-agent >/dev/null 2>&1; } ||
   { [[ "${PKG_FORMAT}" == rpm ]] && rpm -q onboarding-agent >/dev/null 2>&1; }; then
  info "onboarding-agent is already installed"
else
  base="https://${VM_ENDPOINT}/install/${PKG_FORMAT}/${PKG_ARCH}"
  files=()
  for pkg in onboarding-agent istio-sidecar; do
    info "downloading ${pkg}.${PKG_FORMAT}"
    curl -k -fL --retry-all-errors --retry-delay 5 --retry 24 \
      -o "/opt/${pkg}.${PKG_FORMAT}" "${base}/${pkg}.${PKG_FORMAT}" \
      || die "cannot download ${base}/${pkg}.${PKG_FORMAT}"
    files+=("/opt/${pkg}.${PKG_FORMAT}")
  done
  ${PKG_INSTALL} "${files[@]}"
fi
if [[ -x /usr/local/bin/envoy ]] && command -v setcap >/dev/null; then
  setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/envoy
fi

# --- 2. plugin and shim --------------------------------------------------------
log "Installing the credential plugin and the Hydra token shim"
plugin_src="${PLUGIN_SOURCE:-bin/onboarding-agent-ext-jwt-credential-plugin}"
[[ "${plugin_src}" == /* ]] || plugin_src="${SCRIPT_DIR}/${plugin_src}"
if [[ -f "${plugin_src}" ]]; then
  install -m 0755 "${plugin_src}" "${PLUGIN_PATH}"; info "installed ${PLUGIN_PATH}"
elif [[ -x "${PLUGIN_PATH}" ]]; then
  warn "${plugin_src} not found, keeping the plugin at ${PLUGIN_PATH}"
else
  die "plugin binary not found at ${plugin_src} (build it with 'make build-linux-${PKG_ARCH}' in ext-jwt-plugin and copy it to ms-vm/bin/)"
fi

install -m 0755 "${SCRIPT_DIR}/hydra-token-shim.py" "${SHIM_PATH}"
info "installed ${SHIM_PATH}"

AGENT_USER="$(agent_user)"
install -d -m 0755 /etc/onboarding-agent
install -d -o "${AGENT_USER}" -m 0700 /var/lib/onboarding-agent

# shared secret: the plugin proves to the shim that it is the caller
if [[ ! -f "${SHIM_SECRET_FILE}" ]]; then
  umask 077
  head -c 32 /dev/urandom | base64 | tr -d '\n=' >"${SHIM_SECRET_FILE}"
  info "generated ${SHIM_SECRET_FILE}"
fi
# readable by the agent user (the plugin) and the hydra user (the shim)
chown "${AGENT_USER}" "${SHIM_SECRET_FILE}"
chmod 0640 "${SHIM_SECRET_FILE}"
if command -v setfacl >/dev/null; then
  setfacl -m "u:${HYDRA_USER}:r" "${SHIM_SECRET_FILE}" || warn "could not grant ${HYDRA_USER} read access via ACL"
else
  chgrp "$(id -gn "${HYDRA_USER}")" "${SHIM_SECRET_FILE}" \
    || warn "grant ${HYDRA_USER} read access to ${SHIM_SECRET_FILE} yourself"
fi

# --- 3. configuration ----------------------------------------------------------
log "Writing the agent configuration"
if [[ -n "${HYDRA_JWKS_URI:-}" ]]; then
  JWKS_ENV="        - name: EXT_JWT_JWKS_URI
          value: ${HYDRA_JWKS_URI}
        - name: EXT_JWT_VERIFY_TOKEN
          value: \"true\""
else
  JWKS_ENV="        # HYDRA_JWKS_URI is not set: the plugin does not verify the
        # signature itself. The Workload Onboarding Plane still does.
        - name: EXT_JWT_VERIFY_TOKEN
          value: \"false\""
fi
export JWKS_ENV

CONFIG_CHANGED=""
render_template "${SCRIPT_DIR}/templates/agent.config.yaml.tmpl" \
  /etc/onboarding-agent/agent.config.yaml && CONFIG_CHANGED=1
render_template "${SCRIPT_DIR}/templates/onboarding.config.yaml.tmpl" \
  /etc/onboarding-agent/onboarding.config.yaml && CONFIG_CHANGED=1

SHIM_CHANGED=""
render_template "${SCRIPT_DIR}/templates/hydra-token-shim.service.tmpl" \
  /etc/systemd/system/hydra-token-shim.service && SHIM_CHANGED=1

# --- 4. services ----------------------------------------------------------------
log "Starting the token shim"
systemctl daemon-reload
systemctl enable hydra-token-shim >/dev/null 2>&1 || true
if [[ -n "${SHIM_CHANGED}" ]] || ! systemctl is-active --quiet hydra-token-shim; then
  systemctl restart hydra-token-shim
fi
for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://${SHIM_LISTEN_ADDRESS}:${SHIM_LISTEN_PORT}/healthz" && break
  sleep 0.5
done
systemctl is-active --quiet hydra-token-shim \
  || die "the shim did not start: journalctl -u hydra-token-shim -n 50"
info "hydra-token-shim is running on ${SHIM_LISTEN_ADDRESS}:${SHIM_LISTEN_PORT}"

CHECK_FAILED=""
check_token || CHECK_FAILED=1

log "Starting the Onboarding Agent"
systemctl enable onboarding-agent >/dev/null 2>&1 || true
if [[ -n "${CONFIG_CHANGED}" ]] || ! systemctl is-active --quiet onboarding-agent; then
  rm -f "${CREDENTIAL_CACHE_FILE}"
  systemctl restart onboarding-agent
  info "onboarding-agent (re)started"
else
  info "onboarding-agent already running with this configuration"
fi

log "Done"
cat <<EOF
    journalctl -u hydra-token-shim -f      # the token requests
    journalctl -u onboarding-agent -f      # the onboarding itself

EOF
[[ -z "${CHECK_FAILED}" ]] || warn "the token check did not pass - see above; the agent will retry"
