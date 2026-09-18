#!/usr/bin/env bash
#
# Cluster side of the MS VM onboarding: applies every manifest in this directory
# to the cluster that hosts the Workload Onboarding Plane, and merges the
# ControlPlane patch.
#
#   ./install-ms-cp.sh [env file]      # default: ms-cp.env next to this script
#   ./install-ms-cp.sh ms-cp.env --dry-run   # render and show, change nothing
#
# The VM side is in ../ms-vm.
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
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)        die "unknown option: ${arg}" ;;
    *)         ENV_FILE="${arg}" ;;
  esac
done
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/ms-cp.env}"
[[ -f "${ENV_FILE}" ]] || die "env file not found: ${ENV_FILE}"

for tool in kubectl envsubst; do
  command -v "${tool}" >/dev/null || die "${tool} missing"
done

# shellcheck disable=SC1090
source "${ENV_FILE}"
: "${CLUSTER_KUBECONTEXT:?not set in ${ENV_FILE}}"
: "${VM_ENDPOINT:?not set in ${ENV_FILE}}"
: "${HYDRA_ISSUER:?not set in ${ENV_FILE}}"
: "${HYDRA_JWKS_URI:?not set in ${ENV_FILE}}"
: "${APP_NAMESPACE:?not set in ${ENV_FILE}}"
: "${ALLOWED_SUBJECTS:?not set in ${ENV_FILE}}"

# a YAML list item per subject, at the indentation 04-onboarding-policy.yaml expects
ALLOWED_SUBJECTS_BLOCK="$(for s in ${ALLOWED_SUBJECTS}; do printf '        - %s\n' "${s}"; done)"
ALLOWED_SUBJECTS_BLOCK="${ALLOWED_SUBJECTS_BLOCK%$'\n'}"
export ALLOWED_SUBJECTS_BLOCK

kube() { kubectl --context "${CLUSTER_KUBECONTEXT}" "$@"; }

log "Configuring ${CLUSTER_KUBECONTEXT} for VM onboarding through ${VM_ENDPOINT}"
info "issuer:   ${HYDRA_ISSUER}"
info "jwks:     ${HYDRA_JWKS_URI}"
info "subjects: ${ALLOWED_SUBJECTS}"
kube version --request-timeout=10s -o json >/dev/null 2>&1 \
  || die "cannot reach the cluster with context '${CLUSTER_KUBECONTEXT}'"

if [[ -n "${DRY_RUN}" ]]; then
  log "Rendered manifests (not applied)"
  for f in "${SCRIPT_DIR}"/*.yaml; do
    [[ "${f}" == *control-plane* ]] && continue   # merged, not applied
    printf '\n--- %s\n' "$(basename "${f}")"
    envsubst <"${f}"
  done
  printf '\n--- %s (merged into controlplane/controlplane)\n' "02-control-plane-patch.yaml"
  envsubst <"${SCRIPT_DIR}/02-control-plane-patch.yaml"
  exit 0
fi

log "Applying the manifests"
for f in "${SCRIPT_DIR}"/*.yaml; do
  [[ "${f}" == *control-plane* ]] && continue     # merged below, not applied
  info "$(basename "${f}")"
  envsubst <"${f}" | kube apply -f -
done

log "Patching the ControlPlane"
kube patch -n istio-system controlplane controlplane --type=merge \
  -p="$(envsubst <"${SCRIPT_DIR}/02-control-plane-patch.yaml")"

log "Verifying what the Workload Onboarding Plane received"
# the operator renders the ControlPlane into the OnboardingPlane the plane reads
for _ in $(seq 1 24); do
  actual="$(kube -n istio-system get onboardingplane onboarding-plane \
    -o jsonpath='{.spec.workloads.authentication.jwt.issuers[*].issuer}' 2>/dev/null || true)"
  [[ "${actual}" == *"${HYDRA_ISSUER}"* ]] && break
  sleep 5
done
if [[ "${actual:-}" == *"${HYDRA_ISSUER}"* ]]; then
  info "the onboarding plane trusts ${HYDRA_ISSUER}"
else
  warn "after 2 minutes the onboarding plane still does not list ${HYDRA_ISSUER}"
  warn "check: kubectl -n istio-system get onboardingplane onboarding-plane -o yaml"
fi

uid="$(kube -n istio-system get cm onboarding-plane-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
        | awk '/uid:/ {print $2; exit}')"
if [[ -n "${uid}" ]]; then
  info "onboarding plane UID: ${uid}"
  if [[ "${uid}" != "https://${VM_ENDPOINT}" ]]; then
    warn "the VMs receive tokens with aud=https://${VM_ENDPOINT}, which does not match this UID."
    warn "The plane rejects such tokens. The UID follows spec.meshExpansion.onboarding.uid;"
    warn "the onboarding-plane pod may need a restart before it is picked up."
  fi
fi

cat <<EOF

Next:

  1. Point ${VM_ENDPOINT} at the "istio-system/vmgateway" LoadBalancer address:
       kubectl --context ${CLUSTER_KUBECONTEXT} -n istio-system get svc vmgateway

  2. Configure a VM: see ../ms-vm/README.md

  3. Watch a VM onboard:
       kubectl --context ${CLUSTER_KUBECONTEXT} -n istio-system logs deploy/onboarding-plane -f | grep -E 'authenticated a workload|denied'
       kubectl --context ${CLUSTER_KUBECONTEXT} -n ${APP_NAMESPACE} get workloadentry

EOF
