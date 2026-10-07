#!/usr/bin/env bash
#
# Drives the per-cloud stacks. Each cloud is a separate Terraform root with its
# own state, so "AWS only" needs AWS credentials and nothing else - but one
# command still covers several clouds at once.
#
#   ./deploy.sh plan                 # the clouds listed in deploy.conf
#   ./deploy.sh apply aws            # just AWS
#   ./deploy.sh apply aws azure      # AWS and Azure, one after the other
#   ./deploy.sh output aws           # the outputs of one stack
#   ./deploy.sh onboard              # print the push-to-vm.sh command per instance
#   ./deploy.sh destroy aws
#
# Commands: init, plan, apply, destroy, output, onboard, fmt, validate
#
# Each stack is given two variable files:
#   common.tfvars          shared settings (SSH, placement, onboarding)
#   stacks/<cloud>/<cloud>.tfvars   that cloud's region, counts and sizes
#
# Outputs are printed and also saved under outputs/ (override with OUTPUT_DIR):
#   outputs/<cloud>.txt           the readable form, as printed
#   outputs/<cloud>.json          the same, for jq and scripts
#   outputs/<cloud>-onboard.sh    a runnable onboarding script (./deploy.sh onboard)
#
# Extra arguments after -- go straight to Terraform:
#   ./deploy.sh apply aws -- -auto-approve
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_CLOUDS=(aws gcp azure)

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

command -v terraform >/dev/null || die "terraform is not installed"

# --- arguments ----------------------------------------------------------------
COMMAND="${1:-}"
[[ -n "${COMMAND}" ]] || { sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0; }
shift

case "${COMMAND}" in
  init|plan|apply|destroy|output|onboard|fmt|validate) ;;
  -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) die "unknown command: ${COMMAND}. One of: init plan apply destroy output onboard fmt validate" ;;
esac

CLOUDS=()
PASSTHRU=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; PASSTHRU=("$@"); break ;;
    aws|gcp|azure) CLOUDS+=("$1"); shift ;;
    *) die "unexpected argument '$1'. Clouds are: ${ALL_CLOUDS[*]}" ;;
  esac
done

# No clouds named: fall back to deploy.conf, so a plain './deploy.sh apply'
# does what this checkout is configured for.
if [[ ${#CLOUDS[@]} -eq 0 && -f "${SCRIPT_DIR}/deploy.conf" ]]; then
  # deploy.conf sets CLOUDS as a plain space-separated string. Read it into a
  # scalar of its own first: sourcing a string assignment over an array variable
  # would quietly land it all in element 0.
  CONF_CLOUDS=""
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/deploy.conf"
  CONF_CLOUDS="${CLOUDS[*]}"
  CLOUDS=()
  read -r -a CLOUDS <<<"${CONF_CLOUDS}"
fi

if [[ ${#CLOUDS[@]} -eq 0 ]]; then
  die "no clouds selected.
     Name them:        $0 ${COMMAND} aws
     or set CLOUDS in: ${SCRIPT_DIR}/deploy.conf"
fi

# Reject anything deploy.conf got wrong, with the same message as a bad argument.
for cloud in "${CLOUDS[@]}"; do
  case "${cloud}" in
    aws|gcp|azure) ;;
    *) die "unknown cloud '${cloud}' (from deploy.conf). Clouds are: ${ALL_CLOUDS[*]}" ;;
  esac
done

# fmt and validate are not per-cloud in a meaningful way
if [[ "${COMMAND}" == "fmt" ]]; then
  bold "Formatting"
  terraform fmt -recursive "${SCRIPT_DIR}"
  exit 0
fi

# Where the saved outputs land. Gitignored: they carry addresses and resource
# ids, which are not secrets but are specific to your account.
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/outputs}"

# save_outputs <cloud> <stack dir> - writes this stack's outputs next to the
# printed ones, in both the readable and the JSON form, so they can be shared,
# diffed, or piped into jq later without another terraform run.
save_outputs() {
  local cloud="$1" dir="$2"
  local txt="${OUTPUT_DIR}/${cloud}.txt"
  local json="${OUTPUT_DIR}/${cloud}.json"
  local payload

  # The JSON form is the reliable test for "are there any outputs at all":
  # terraform prints its "No outputs found" warning on stdout, so the text form
  # looks non-empty even when there is nothing to save.
  payload="$(terraform -chdir="${dir}" output -json 2>/dev/null || true)"
  if [[ -z "${payload}" || "${payload}" == "{}" ]]; then
    warn "no outputs to save for ${cloud} - has it been applied?"
    return 0
  fi

  mkdir -p "${OUTPUT_DIR}"

  # -no-color: these files get shared and read in editors, where escape codes
  # are just noise.
  {
    printf '# terraform output - %s stack\n' "${cloud}"
    printf '# written %s by deploy.sh %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${COMMAND}"
    printf '#\n# Regenerate with: ./deploy.sh output %s\n\n' "${cloud}"
    terraform -chdir="${dir}" output -no-color 2>/dev/null
  } >"${txt}"

  printf '%s\n' "${payload}" >"${json}"

  info "saved ${txt#"${SCRIPT_DIR}/"}"
  info "saved ${json#"${SCRIPT_DIR}/"}"
}

COMMON_VARS="${SCRIPT_DIR}/common.tfvars"
[[ -f "${COMMON_VARS}" ]] || die "missing ${COMMON_VARS}
     Copy the example and edit it:
       cp '${SCRIPT_DIR}/common.tfvars.example' '${COMMON_VARS}'"

# --- run one stack ------------------------------------------------------------
run_stack() {
  local cloud="$1" dir="${SCRIPT_DIR}/stacks/$1"
  [[ -d "${dir}" ]] || die "no stack for '${cloud}'"

  local cloud_vars="${dir}/${cloud}.tfvars"
  local -a var_args=(-var-file="${COMMON_VARS}")
  if [[ -f "${cloud_vars}" ]]; then
    var_args+=(-var-file="${cloud_vars}")
  else
    warn "${cloud}.tfvars not found, using the stack defaults only"
    warn "  cp '${cloud_vars}.example' '${cloud_vars}'"
  fi

  bold "${cloud}: terraform ${COMMAND}"

  # init is cheap and idempotent, and skipping it is the usual cause of a
  # confusing failure after a module changes
  if [[ ! -d "${dir}/.terraform" || "${COMMAND}" == "init" ]]; then
    terraform -chdir="${dir}" init -input=false ${TF_INIT_ARGS:-}
  fi
  [[ "${COMMAND}" == "init" ]] && return 0

  case "${COMMAND}" in
    validate)
      terraform -chdir="${dir}" validate
      ;;
    output)
      terraform -chdir="${dir}" output "${PASSTHRU[@]+"${PASSTHRU[@]}"}"
      save_outputs "${cloud}" "${dir}"
      ;;
    onboard)
      # The ready-made push-to-vm.sh invocations for this stack's instances,
      # printed and also written out as a script that can be run as-is.
      local script="${OUTPUT_DIR}/${cloud}-onboard.sh"
      local cmds lines
      cmds="$(terraform -chdir="${dir}" output -json onboard_commands 2>/dev/null || true)"

      if [[ -z "${cmds}" || "${cmds}" == "null" ]]; then
        info "(no instances yet - run apply first)"
      else
        lines="$(printf '%s' "${cmds}" | python3 -c 'import json,sys
for c in json.load(sys.stdin):
    print(c)')"

        printf '%s\n' "${lines}" | sed 's/^/    /'

        mkdir -p "${OUTPUT_DIR}"
        {
          printf '#!/usr/bin/env bash\n#\n'
          printf '# Onboard the %s instances into the mesh.\n' "${cloud}"
          printf '# Written by deploy.sh on %s - re-run "./deploy.sh onboard %s" to refresh.\n#\n' \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${cloud}"
          printf '# Run it from the vm/ directory. The client secret comes from the\n'
          printf '# environment and is deliberately not written into this file:\n#\n'
          printf '#   cd vm\n'
          printf '#   KEYCLOAK_CLIENT_SECRET=... bash ../terraform/outputs/%s-onboard.sh\n#\n' "${cloud}"
          printf '# Add SSH_KEY=<path to the private key> if ssh does not pick yours by default.\n'
          printf 'set -euo pipefail\n'
          printf ': "${KEYCLOAK_CLIENT_SECRET:?set it in the environment before running this}"\n\n'
          # Drop the placeholder assignment; the real value is already exported.
          printf '%s\n' "${lines}" | sed "s/KEYCLOAK_CLIENT_SECRET='<secret>' //"
        } >"${script}"
        chmod +x "${script}"
        info "saved ${script#"${SCRIPT_DIR}/"}"
      fi
      ;;
    plan|apply|destroy)
      terraform -chdir="${dir}" "${COMMAND}" -input=false \
        "${var_args[@]}" "${PASSTHRU[@]+"${PASSTHRU[@]}"}"

      # Terraform prints the outputs itself after an apply; this keeps a copy.
      if [[ "${COMMAND}" == "apply" ]]; then
        save_outputs "${cloud}" "${dir}"
      fi
      # After a destroy the saved files describe things that no longer exist.
      if [[ "${COMMAND}" == "destroy" ]]; then
        rm -f "${OUTPUT_DIR}/${cloud}.txt" "${OUTPUT_DIR}/${cloud}.json" \
              "${OUTPUT_DIR}/${cloud}-onboard.sh"
      fi
      ;;
  esac
}

info "clouds: ${CLOUDS[*]}"
for cloud in "${CLOUDS[@]}"; do
  run_stack "${cloud}"
done

if [[ "${COMMAND}" == "apply" ]]; then
  cat <<EOF

$(bold "Next")
    The instances are prepared but NOT onboarded yet. To onboard them:

      ./deploy.sh onboard ${CLOUDS[*]}

    then run each printed command from the vm/ directory, with the real
    Keycloak client secret substituted for <secret>.

    The outputs are also saved, so you do not have to re-run terraform:

      ${OUTPUT_DIR#"${SCRIPT_DIR}/"}/<cloud>.txt     the readable form
      ${OUTPUT_DIR#"${SCRIPT_DIR}/"}/<cloud>.json    for jq and scripts

EOF
fi
