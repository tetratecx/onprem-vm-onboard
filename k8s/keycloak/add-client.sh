#!/usr/bin/env bash
#
# Creates a service-account client in the Keycloak realm for a VM (or a group of
# VMs) that onboards with the External JWT Credential Plugin.
#
# The client is given everything a token needs to pass onboarding:
#   - the client_credentials grant (service accounts), no end user involved
#   - an Audience mapper putting the Workload Onboarding Plane UID in 'aud'
#   - hardcoded claims under 'custom_attributes' (region, datacenter,
#     access_level), which is what an OnboardingPolicy matches on
#
# Usage:
#   ./add-client.sh --client-id vm-rhel-prod \
#                   --secret '<a strong secret>' \
#                   --plane-uid https://vms.tsb-ms-demo.aws-ce.sandbox.tetrate.io \
#                   --region uscentral1 --datacenter datacenter1
#
#   --replace   delete an existing client with the same id first
#
# Needs kubectl access to the cluster running Keycloak; runs kcadm.sh inside the
# pod. The admin password comes from KC_ADMIN_PASSWORD or is prompted for.
#
# It finishes by requesting a token and printing its claims, including the 'sub'
# to put in ALLOWED_SUBJECTS in ../cp.env.
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
REALM="${REALM:-tetrate}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
# public URL of Keycloak, used only for the token request at the end
KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak.apigw.aws-ce.sandbox.tetrate.io}"

CLIENT_ID=""; CLIENT_SECRET=""; PLANE_UID=""
ACCESS_LEVEL="write"; REGION="uscentral1"; DATACENTER="datacenter1"; REPLACE=""

usage() { sed -n '3,22p' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-id)    CLIENT_ID="$2"; shift 2 ;;
    --secret)       CLIENT_SECRET="$2"; shift 2 ;;
    --plane-uid)    PLANE_UID="$2"; shift 2 ;;
    --access-level) ACCESS_LEVEL="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --datacenter)   DATACENTER="$2"; shift 2 ;;
    --replace)      REPLACE=1; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

[[ -n "${CLIENT_ID}" ]]     || { echo "--client-id is required" >&2; usage 1; }
[[ -n "${CLIENT_SECRET}" ]] || { echo "--secret is required" >&2; usage 1; }
[[ -n "${PLANE_UID}" ]]     || { echo "--plane-uid is required" >&2; usage 1; }

for tool in kubectl jq curl; do
  command -v "${tool}" >/dev/null || { echo "${tool} missing" >&2; exit 1; }
done

if [[ -z "${KC_ADMIN_PASSWORD:-}" ]]; then
  read -r -s -p "Keycloak admin password for '${KC_ADMIN_USER}': " KC_ADMIN_PASSWORD
  echo
fi

kc() { kubectl -n "${NAMESPACE}" exec -i deploy/keycloak -- \
         /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }

cleanup() { kubectl -n "${NAMESPACE}" exec deploy/keycloak -- rm -f /tmp/kcadm.config >/dev/null 2>&1 || true; }
trap cleanup EXIT

# the password goes in over stdin, never on a command line visible in the pod
kubectl -n "${NAMESPACE}" exec -i deploy/keycloak -- sh -c \
  'read -r p; /opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm.config \
     --server http://localhost:8080 --realm master --user "$1" --password "$p"' \
  _ "${KC_ADMIN_USER}" <<<"${KC_ADMIN_PASSWORD}"

# a clientId may contain ':' and '/', which do not survive a -q query parameter,
# so list the clients and match locally
client_uuid() {
  kc get clients -r "${REALM}" --fields id,clientId --format json \
    | jq -r --arg c "${CLIENT_ID}" '.[] | select(.clientId == $c) | .id'
}

existing="$(client_uuid)"
if [[ -n "${existing}" ]]; then
  if [[ -n "${REPLACE}" ]]; then
    echo "==> deleting the existing client '${CLIENT_ID}'"
    kc delete "clients/${existing}" -r "${REALM}"
  else
    echo "client '${CLIENT_ID}' already exists in realm '${REALM}'; pass --replace to recreate it" >&2
    exit 1
  fi
fi

echo "==> creating client '${CLIENT_ID}' in realm '${REALM}'"
kc create clients -r "${REALM}" \
  -s "clientId=${CLIENT_ID}" \
  -s "name=VM onboarding client (${ACCESS_LEVEL})" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s bearerOnly=false \
  -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false \
  -s implicitFlowEnabled=false \
  -s directAccessGrantsEnabled=false \
  -s "secret=${CLIENT_SECRET}" \
  -s 'attributes."access.token.signed.response.alg"=RS256'

uuid="$(client_uuid)"
[[ -n "${uuid}" ]] || { echo "the client was not created" >&2; exit 1; }

# hardcoded_claim <mapper name> <claim name> <value>
hardcoded_claim() {
  kc create "clients/${uuid}/protocol-mappers/models" -r "${REALM}" \
    -s "name=$1" \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-hardcoded-claim-mapper \
    -s "config.\"claim.name\"=$2" \
    -s "config.\"claim.value\"=$3" \
    -s 'config."jsonType.label"=String' \
    -s 'config."access.token.claim"=true' \
    -s 'config."id.token.claim"=false' \
    -s 'config."introspection.token.claim"=true'
  echo "    mapper $1: $2=$3"
}

echo "==> adding the protocol mappers"
kc create "clients/${uuid}/protocol-mappers/models" -r "${REALM}" \
  -s name=onboarding-plane-audience \
  -s protocol=openid-connect \
  -s protocolMapper=oidc-audience-mapper \
  -s "config.\"included.custom.audience\"=${PLANE_UID}" \
  -s 'config."access.token.claim"=true' \
  -s 'config."id.token.claim"=false' \
  -s 'config."introspection.token.claim"=true'
echo "    mapper onboarding-plane-audience: aud += ${PLANE_UID}"

# these land under 'custom_attributes', which is what the OnboardingPolicy reads
hardcoded_claim attr-region       custom_attributes.region       "${REGION}"
hardcoded_claim attr-datacenter   custom_attributes.datacenter   "${DATACENTER}"
hardcoded_claim attr-access-level custom_attributes.access_level "${ACCESS_LEVEL}"

echo "==> requesting a token to show what the client issues"
token="$(curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}" \
  -d grant_type=client_credentials | jq -r '.access_token // empty')"

if [[ -z "${token}" ]]; then
  echo "could not obtain a token - check that ${KEYCLOAK_URL} is reachable from here" >&2
  exit 1
fi

payload="$(cut -d. -f2 <<<"${token}" | tr '_-' '/+')"
while (( ${#payload} % 4 )); do payload+="="; done
claims="$(base64 -d <<<"${payload}" 2>/dev/null)"
jq -r '{sub, iss, aud, azp, custom_attributes, exp: (.exp | todate)}' <<<"${claims}"

sub="$(jq -r .sub <<<"${claims}")"

cat <<EOF

Client created. Add its subject to the OnboardingPolicy in ../cp.env:

  export ALLOWED_SUBJECTS="${sub}"
  export ALLOWED_ATTRIBUTES="region=${REGION} datacenter=${DATACENTER}"

then re-apply the control plane:

  cd .. && ./install-cp.sh

and on the VM, in ../../vm/vm.env:

  KEYCLOAK_CLIENT_ID="${CLIENT_ID}"
  KEYCLOAK_CLIENT_SECRET="<the secret you passed>"   # better: pass it in the environment
EOF
