#!/usr/bin/env bash
#
# Fetches a JWT from Keycloak the same way the Onboarding Agent does, and checks
# the claims the Workload Onboarding Plane will judge it by.
#
# This is a plain OAuth 2.0 client_credentials request - one HTTP POST, nothing
# else. Use it to prove the token side works before, or independently of, the
# agent.
#
#   ./get-token.sh                 # print the raw access token
#   ./get-token.sh --decode        # print the claims and validate iss / aud / exp
#   ./get-token.sh --check         # run the plugin's own end-to-end check
#   ./get-token.sh --curl          # print the equivalent curl command, run nothing
#   ./get-token.sh vm.env.local --decode
#
# The client secret is taken from, in order: $KEYCLOAK_CLIENT_SECRET, the env
# file, then /etc/onboarding-agent/client-secret (which needs root or the
# onboarding-agent user).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_SECRET_FILE="/etc/onboarding-agent/client-secret"
PLUGIN_PATH="/usr/local/bin/onboarding-agent-ext-jwt-credential-plugin"

info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

ENV_FILE=""; MODE="raw"
for arg in "$@"; do
  case "${arg}" in
    --decode) MODE="decode" ;;
    --check)  MODE="check" ;;
    --curl)   MODE="curl" ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)       die "unknown option: ${arg}" ;;
    *)        ENV_FILE="${arg}" ;;
  esac
done
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/vm.env}"
[[ -f "${ENV_FILE}" ]] || die "env file not found: ${ENV_FILE}"

command -v curl >/dev/null || die "curl missing"

SECRET_FROM_ENV="${KEYCLOAK_CLIENT_SECRET:-}"
# shellcheck disable=SC1090
source "${ENV_FILE}"
[[ -n "${SECRET_FROM_ENV}" ]] && KEYCLOAK_CLIENT_SECRET="${SECRET_FROM_ENV}"

: "${KEYCLOAK_REALM_URL:?not set in ${ENV_FILE}}"
: "${KEYCLOAK_CLIENT_ID:?not set in ${ENV_FILE}}"
KEYCLOAK_REALM_URL="${KEYCLOAK_REALM_URL%/}"
TOKEN_ENDPOINT="${KEYCLOAK_REALM_URL}/protocol/openid-connect/token"

# --- print the equivalent request and stop -----------------------------------
# No secret is needed here: the command it prints reads the secret from the file
# the agent uses, so it can be run on a VM where this script cannot read it.
if [[ "${MODE}" == "curl" ]]; then
  cat <<EOF
# The token request the Onboarding Agent's credential plugin makes.
# The secret is read from the file rather than put on the command line.
curl -s -X POST '${TOKEN_ENDPOINT}' \\
  -H 'Content-Type: application/x-www-form-urlencoded' \\
  -d grant_type=client_credentials \\
  -d client_id='${KEYCLOAK_CLIENT_ID}' \\
  --data-urlencode "client_secret@${CLIENT_SECRET_FILE}"${KEYCLOAK_CA_FILE:+ \\
  --cacert '${KEYCLOAK_CA_FILE}'}
EOF
  exit 0
fi

# the secret: environment or env file, else the file the agent itself reads
if [[ -z "${KEYCLOAK_CLIENT_SECRET:-}" ]]; then
  if [[ -r "${CLIENT_SECRET_FILE}" ]]; then
    KEYCLOAK_CLIENT_SECRET="$(cat "${CLIENT_SECRET_FILE}")"
  else
    die "no client secret: set KEYCLOAK_CLIENT_SECRET, put it in ${ENV_FILE}, or run
     this as root so ${CLIENT_SECRET_FILE} can be read"
  fi
fi

# extra curl options for a Keycloak behind a corporate CA
CURL_OPTS=(-s --max-time 30)
[[ -n "${KEYCLOAK_CA_FILE:-}" ]] && CURL_OPTS+=(--cacert "${KEYCLOAK_CA_FILE}")

# --- the plugin's own check: token request + iss + signature + aud ------------
if [[ "${MODE}" == "check" ]]; then
  [[ -x "${PLUGIN_PATH}" ]] || die "${PLUGIN_PATH} is not installed; run install-vm.sh first"
  : "${ONBOARDING_PLANE_UID:?not set in ${ENV_FILE}; the audience is what 'check' verifies}"
  # shellcheck source=lib/common.sh
  source "${SCRIPT_DIR}/lib/common.sh"
  mapfile -t env_args < <(plugin_env)
  exec env "${env_args[@]}" "${PLUGIN_PATH}" check --audience "${ONBOARDING_PLANE_UID}"
fi

# --- the token request --------------------------------------------------------
response="$(curl "${CURL_OPTS[@]}" -X POST "${TOKEN_ENDPOINT}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d grant_type=client_credentials \
  --data-urlencode "client_id=${KEYCLOAK_CLIENT_ID}" \
  --data-urlencode "client_secret=${KEYCLOAK_CLIENT_SECRET}")" \
  || die "could not reach ${TOKEN_ENDPOINT} - is Keycloak reachable from this VM?
     curl -sv ${KEYCLOAK_REALM_URL}/.well-known/openid-configuration"

# pull access_token out without needing jq
token="$(printf '%s' "${response}" \
  | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

if [[ -z "${token}" ]]; then
  printf '\033[31mno access_token in the response:\033[0m\n%s\n' "${response}" >&2
  case "${response}" in
    *invalid_client*) warn "wrong client id or secret. A trailing newline in the secret file is
         the usual cause - write it with printf, not echo." ;;
    *unauthorized_client*) warn "the client exists but has no service account: enable
         'Service accounts roles' (the client_credentials grant) on it." ;;
  esac
  exit 1
fi

if [[ "${MODE}" == "raw" ]]; then
  printf '%s\n' "${token}"
  exit 0
fi

# --- decode and validate ------------------------------------------------------
if ! command -v python3 >/dev/null; then
  warn "python3 not found: printing the raw claims without validating them"
  payload="$(cut -d. -f2 <<<"${token}" | tr '_-' '/+')"
  while (( ${#payload} % 4 )); do payload+="="; done
  base64 -d <<<"${payload}" 2>/dev/null || base64 -D <<<"${payload}"
  echo
  exit 0
fi

python3 - "${token}" "${ONBOARDING_PLANE_UID:-}" "${KEYCLOAK_REALM_URL}" <<'PY'
import base64, json, sys, time

token, want_aud, want_iss = sys.argv[1], sys.argv[2], sys.argv[3]
payload = token.split(".")[1]
payload += "=" * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))

print(json.dumps(claims, indent=2, sort_keys=True))

aud = claims.get("aud")
aud = aud if isinstance(aud, list) else ([aud] if aud else [])
exp_in = int(claims.get("exp", 0) - time.time())

print("\nWhat the Workload Onboarding Plane checks:")
ok = True

def report(good, label, detail=""):
    global ok
    print(f"  [{' ok ' if good else 'fail'}] {label}{(' - ' + detail) if detail else ''}")
    if not good:
        ok = False

report(claims.get("iss") == want_iss, "'iss' matches the trusted issuer",
       "" if claims.get("iss") == want_iss else
       f"token says {claims.get('iss')!r}, the ControlPlane trusts {want_iss!r}")

if want_aud:
    report(want_aud in aud, "'aud' contains the onboarding plane UID",
           "" if want_aud in aud else
           f"aud is {aud}, missing {want_aud!r}. Add the Audience mapper: "
           "k8s/keycloak/add-audience.sh")
else:
    print("  [skip] no ONBOARDING_PLANE_UID set, 'aud' not checked")

report(bool(claims.get("sub")), "'sub' is present",
       "" if claims.get("sub") else "the OnboardingPolicy matches on this")
report(exp_in > 0, f"the token is valid for another {exp_in}s")

attrs = claims.get("custom_attributes")
if attrs:
    pairs = " ".join(f"{k}={v}" for k, v in sorted(attrs.items()))
    print(f"\n  custom_attributes: {pairs}")
    print("  -> ALLOWED_ATTRIBUTES in k8s/cp.env must be a subset of these")
else:
    print("\n  no 'custom_attributes' in the token: leave ALLOWED_ATTRIBUTES empty in"
          "\n  k8s/cp.env, or add the claim mappers with k8s/keycloak/add-client.sh")

if claims.get("sub"):
    print(f"\n  ALLOWED_SUBJECTS in k8s/cp.env must include: {claims['sub']}")

sys.exit(0 if ok else 1)
PY
