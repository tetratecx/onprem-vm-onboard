#!/usr/bin/env bash
#
# Adds the UID of the Workload Onboarding Plane to the 'aud' claim of the tokens
# Keycloak issues to the VM clients.
#
# Required once per plane UID. The plane rejects a token whose 'aud' does not
# contain its UID, and Keycloak ignores the 'audience' request parameter that the
# credential plugin sends with the client_credentials grant - so the audience has
# to come from an Audience protocol mapper on the client instead.
#
# Usage:
#   ./add-audience.sh <plane-uid>                      # all clients in CLIENTS below
#   ./add-audience.sh <plane-uid> vm-write             # just one client
#
#   ./add-audience.sh https://vms.tsb-ms-demo.aws-ce.sandbox.tetrate.io
#
# Runs kcadm.sh inside the Keycloak pod, so it needs only kubectl access to the
# cluster running Keycloak. The admin password comes from KC_ADMIN_PASSWORD or is
# prompted for.
#
# Idempotent: a mapper with the same name is replaced, so re-running is safe.
set -euo pipefail

PLANE_UID="${1:?usage: $0 <workload-onboarding-plane-uid> [client ...]}"
shift
CLIENTS=("$@")
[[ $# -eq 0 ]] && CLIENTS=(vm-write vm-readonly)

NAMESPACE="${NAMESPACE:-keycloak}"
REALM="${REALM:-tetrate}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
MAPPER_NAME="${MAPPER_NAME:-onboarding-plane-audience}"

command -v kubectl >/dev/null || { echo "kubectl missing" >&2; exit 1; }

if [[ -z "${KC_ADMIN_PASSWORD:-}" ]]; then
  read -r -s -p "Keycloak admin password for '${KC_ADMIN_USER}': " KC_ADMIN_PASSWORD
  echo
fi

kc() {
  kubectl -n "${NAMESPACE}" exec -i deploy/keycloak -- /opt/keycloak/bin/kcadm.sh "$@" \
    --config /tmp/kcadm.config
}

cleanup() { kubectl -n "${NAMESPACE}" exec deploy/keycloak -- rm -f /tmp/kcadm.config >/dev/null 2>&1 || true; }
trap cleanup EXIT

# log in through the pod's local HTTP listener; the password goes in over stdin,
# never on a command line visible in the pod's process list
kubectl -n "${NAMESPACE}" exec -i deploy/keycloak -- sh -c \
  'read -r p; /opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm.config \
     --server http://localhost:8080 --realm master --user "$1" --password "$p"' \
  _ "${KC_ADMIN_USER}" <<<"${KC_ADMIN_PASSWORD}"

for client in "${CLIENTS[@]}"; do
  id="$(kc get clients -r "${REALM}" -q "clientId=${client}" --fields id --format csv --noquotes)"
  if [[ -z "${id}" ]]; then
    echo "client '${client}' not found in realm '${REALM}'" >&2
    exit 1
  fi

  existing="$(kc get "clients/${id}/protocol-mappers/models" -r "${REALM}" --fields id,name --format csv --noquotes \
    | awk -F, -v n="${MAPPER_NAME}" '$2 == n {print $1}')"
  if [[ -n "${existing}" ]]; then
    kc delete "clients/${id}/protocol-mappers/models/${existing}" -r "${REALM}"
  fi

  kc create "clients/${id}/protocol-mappers/models" -r "${REALM}" \
    -s "name=${MAPPER_NAME}" \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s "config.\"included.custom.audience\"=${PLANE_UID}" \
    -s 'config."access.token.claim"=true' \
    -s 'config."id.token.claim"=false' \
    -s 'config."introspection.token.claim"=true'

  echo "client '${client}': tokens now carry aud '${PLANE_UID}'"
done

cat <<EOF

Confirm from the VM, with the cached credential cleared:

  cd ../../vm
  ./get-token.sh --decode | grep -E '"(sub|aud|iss)"'
  sudo rm -f /var/lib/onboarding-agent/ext-jwt-credential.cache
  sudo systemctl restart onboarding-agent
EOF
