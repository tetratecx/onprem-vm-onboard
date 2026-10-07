#!/usr/bin/env bash
#
# Control-plane side of VM onboarding with Keycloak-issued JWTs.
#
# Applies every manifest in this directory to the cluster that hosts the Workload
# Onboarding Plane, merges the ControlPlane patch, then reports what the
# onboarding plane actually picked up:
#
#   - the issuer it now trusts
#   - its UID, which must be in the 'aud' claim of the VM tokens
#   - the vmgateway address the DNS record has to point at
#
#   ./install-cp.sh                      # uses cp.env next to this script
#   ./install-cp.sh cp.env.local         # or your own copy
#   ./install-cp.sh --dry-run            # render and print, change nothing
#
# The VM side is in ../vm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

ENV_FILE=""; DRY_RUN=""
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)        die "unknown option: ${arg}" ;;
    *)         ENV_FILE="${arg}" ;;
  esac
done
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/cp.env}"
[[ -f "${ENV_FILE}" ]] || die "env file not found: ${ENV_FILE}"

# Associative arrays are used to group the policy attributes, so bash 4 or newer
# is required. macOS still ships 3.2 as /bin/bash: 'brew install bash' provides a
# newer one that 'env bash' then picks up.
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] \
  || die "bash 4 or newer is required (this is ${BASH_VERSION}).
     On macOS: brew install bash"

for tool in kubectl envsubst; do
  command -v "${tool}" >/dev/null || die "${tool} missing
     On macOS: brew install kubectl gettext && brew link --force gettext"
done

# shellcheck disable=SC1090
source "${ENV_FILE}"
: "${CLUSTER_KUBECONTEXT:?not set in ${ENV_FILE}}"
: "${VM_ENDPOINT:?not set in ${ENV_FILE}}"
: "${KEYCLOAK_REALM_URL:?not set in ${ENV_FILE}}"
: "${APP_NAMESPACE:?not set in ${ENV_FILE}}"
: "${APP_NAME:?not set in ${ENV_FILE}}"
: "${WORKLOAD_GROUP_NAME:?not set in ${ENV_FILE}}"
: "${ALLOWED_SUBJECTS:?not set in ${ENV_FILE}}"

# --- values derived from the realm URL ----------------------------------------
# The realm URL is the 'iss' claim; the JWKS document hangs off it. A trailing
# slash would make the issuer string stop matching the token.
KEYCLOAK_REALM_URL="${KEYCLOAK_REALM_URL%/}"
KEYCLOAK_ISSUER="${KEYCLOAK_REALM_URL}"
KEYCLOAK_JWKS_URI="${KEYCLOAK_REALM_URL}/protocol/openid-connect/certs"
KEYCLOAK_SHORT_NAME="${KEYCLOAK_SHORT_NAME:-keycloak}"
INSTALL_CERT="${INSTALL_CERT:-true}"
CERT_ISSUER_NAME="${CERT_ISSUER_NAME:-selfsigned-ca}"
CERT_ISSUER_KIND="${CERT_ISSUER_KIND:-ClusterIssuer}"
PLANE_UID="https://${VM_ENDPOINT}"

# --- the policy lists, rendered at the indentation the manifest expects -------
ALLOWED_SUBJECTS_BLOCK="$(for s in ${ALLOWED_SUBJECTS}; do printf '        - %s\n' "${s}"; done)"
ALLOWED_SUBJECTS_BLOCK="${ALLOWED_SUBJECTS_BLOCK%$'\n'}"

# "region=uscentral1 datacenter=datacenter1" becomes a list of {name, values},
# grouping repeated names so that region=a region=b allows either value
ALLOWED_ATTRIBUTES_BLOCK=""
if [[ -n "${ALLOWED_ATTRIBUTES:-}" ]]; then
  declare -a attr_names=()
  declare -A attr_values=()
  for pair in ${ALLOWED_ATTRIBUTES}; do
    [[ "${pair}" == *=* ]] || die "ALLOWED_ATTRIBUTES entry '${pair}' is not name=value"
    name="${pair%%=*}"; value="${pair#*=}"
    [[ -n "${attr_values[${name}]:-}" ]] || attr_names+=("${name}")
    attr_values["${name}"]+="${value} "
  done
  ALLOWED_ATTRIBUTES_BLOCK="        attributes:"
  for name in "${attr_names[@]}"; do
    ALLOWED_ATTRIBUTES_BLOCK+=$'\n'"        - name: ${name}"$'\n'"          values:"
    for value in ${attr_values[${name}]}; do
      ALLOWED_ATTRIBUTES_BLOCK+=$'\n'"          - ${value}"
    done
  done
fi

export VM_ENDPOINT APP_NAMESPACE APP_NAME WORKLOAD_GROUP_NAME \
       KEYCLOAK_ISSUER KEYCLOAK_JWKS_URI KEYCLOAK_SHORT_NAME \
       CERT_ISSUER_NAME CERT_ISSUER_KIND \
       ALLOWED_SUBJECTS_BLOCK ALLOWED_ATTRIBUTES_BLOCK

kube() { kubectl --context "${CLUSTER_KUBECONTEXT}" "$@"; }

# every manifest except the ControlPlane patch, which is merged rather than applied
manifests() {
  local f
  for f in "${SCRIPT_DIR}"/[0-9]*.yaml; do
    [[ "${f}" == *control-plane* ]] && continue
    [[ "${f}" == *01-cert* && "${INSTALL_CERT}" != "true" ]] && continue
    printf '%s\n' "${f}"
  done
}

log "Configuring ${CLUSTER_KUBECONTEXT} for VM onboarding through ${VM_ENDPOINT}"
info "issuer:     ${KEYCLOAK_ISSUER}"
info "jwks:       ${KEYCLOAK_JWKS_URI}"
info "plane uid:  ${PLANE_UID}"
info "workload:   ${APP_NAMESPACE}/${WORKLOAD_GROUP_NAME}"
info "subjects:   ${ALLOWED_SUBJECTS}"
info "attributes: ${ALLOWED_ATTRIBUTES:-<none>}"

if [[ -n "${DRY_RUN}" ]]; then
  log "Rendered manifests (nothing applied)"
  while read -r f; do
    printf '\n--- %s\n' "$(basename "${f}")"
    envsubst <"${f}"
  done < <(manifests)
  printf '\n--- 02-control-plane-patch.yaml (merged into controlplane/controlplane)\n'
  envsubst <"${SCRIPT_DIR}/02-control-plane-patch.yaml"
  exit 0
fi

kube version --request-timeout=10s -o json >/dev/null 2>&1 \
  || die "cannot reach the cluster with context '${CLUSTER_KUBECONTEXT}'"

log "Applying the manifests"
while read -r f; do
  info "$(basename "${f}")"
  envsubst <"${f}" | kube apply -f -
done < <(manifests)
[[ "${INSTALL_CERT}" == "true" ]] || info "01-cert.yaml skipped (INSTALL_CERT is not \"true\")"

log "Merging the ControlPlane patch"
# --type=merge, never 'apply': the ControlPlane holds much more than these fields
kube patch -n istio-system controlplane controlplane --type=merge \
  -p="$(envsubst <"${SCRIPT_DIR}/02-control-plane-patch.yaml")"

log "Verifying what the Workload Onboarding Plane received"
# the TSB operator renders the ControlPlane into the OnboardingPlane the plane reads
actual=""
for _ in $(seq 1 24); do
  actual="$(kube -n istio-system get onboardingplane onboarding-plane \
    -o jsonpath='{.spec.workloads.authentication.jwt.issuers[*].issuer}' 2>/dev/null || true)"
  [[ "${actual}" == *"${KEYCLOAK_ISSUER}"* ]] && break
  sleep 5
done
if [[ "${actual}" == *"${KEYCLOAK_ISSUER}"* ]]; then
  info "the onboarding plane trusts ${KEYCLOAK_ISSUER}"
else
  warn "after 2 minutes the onboarding plane still does not list ${KEYCLOAK_ISSUER}"
  warn "check: kubectl --context ${CLUSTER_KUBECONTEXT} -n istio-system get onboardingplane onboarding-plane -o yaml"
fi

uid="$(kube -n istio-system get cm onboarding-plane-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
        | awk '/uid:/ {print $2; exit}')"
if [[ -n "${uid}" ]]; then
  info "onboarding plane UID: ${uid}"
  if [[ "${uid}" != "${PLANE_UID}" ]]; then
    warn "this does not match https://${VM_ENDPOINT}, which is what the Keycloak"
    warn "Audience mapper and vm/vm.env are set up for. The onboarding-plane pod"
    warn "may not have reloaded yet; re-run this script to check again."
  fi
else
  warn "could not read the plane UID from the onboarding-plane-config ConfigMap"
  uid="${PLANE_UID}"
fi

lb="$(kube -n istio-system get svc vmgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

cat <<EOF

$(log "Next steps")
  1. DNS: point ${VM_ENDPOINT} at the vmgateway
       ${lb:-<run: kubectl --context ${CLUSTER_KUBECONTEXT} -n istio-system get svc vmgateway>}

  2. Keycloak: the clients must mint tokens whose 'aud' contains the plane UID
       ./keycloak/add-audience.sh '${uid}'

  3. VM: see ../vm/README.md, with
       ONBOARDING_PLANE_UID="${uid}"
       WORKLOAD_GROUP_NAMESPACE="${APP_NAMESPACE}"
       WORKLOAD_GROUP_NAME="${WORKLOAD_GROUP_NAME}"

  4. Watch a VM onboard
       kubectl --context ${CLUSTER_KUBECONTEXT} -n istio-system logs deploy/onboarding-plane -f | grep -E 'authenticated a workload|denied'
       kubectl --context ${CLUSTER_KUBECONTEXT} -n ${APP_NAMESPACE} get workloadentry

EOF
