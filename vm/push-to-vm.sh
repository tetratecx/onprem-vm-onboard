#!/usr/bin/env bash
#
# Copies this directory to a VM and runs install-vm.sh there. Run it from your
# laptop - nothing has to be moved onto the VM by hand:
#
#   ./push-to-vm.sh ec2-user@10.0.1.20
#   SSH_KEY=~/.ssh/vm.pem ./push-to-vm.sh ec2-user@10.0.1.20
#   ENV_FILE=vm.env.local ./push-to-vm.sh ec2-user@10.0.1.20
#   ./push-to-vm.sh ec2-user@10.0.1.20 --check-only
#
# Reaching a VM in a private subnet, through the public mesh VM that doubles as
# the jump host:
#
#   SSH_JUMP=ec2-user@203.0.113.9 SSH_KEY=~/.ssh/vm.pem \
#     ./push-to-vm.sh ec2-user@10.42.100.87
#
# Keeps the Keycloak client secret out of any file on the VM when it is passed in
# the environment:
#
#   KEYCLOAK_CLIENT_SECRET='...' ./push-to-vm.sh ec2-user@10.0.1.20
#
# Environment:
#   SSH_KEY     identity file, passed as -i
#   SSH_JUMP    [user@]host to jump through, as -o ProxyJump=
#   SSH_OPTS    any further ssh/scp options, split on whitespace
#   ENV_FILE    the env file install-vm.sh should read (default: vm.env)
#   REMOTE_DIR  where to copy to on the VM
#   DRY_RUN     1 prints the ssh/scp commands instead of running them
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?usage: $0 <user@host> [extra install-vm.sh args]}"
shift || true

ENV_FILE="${ENV_FILE:-vm.env}"
REMOTE_DIR="${REMOTE_DIR:-/home/${TARGET%@*}/vm-onboarding}"

# Options for both ssh and scp. Built into an array of its own so that a value
# the caller put in SSH_OPTS is added rather than overwritten.
ssh_args=()
[[ -n "${SSH_KEY:-}" ]] && ssh_args+=(-i "${SSH_KEY}")

# ProxyJump rather than -J: it means the same thing but is understood by scp on
# every OpenSSH version, whereas scp -J needs 8.0 or newer.
[[ -n "${SSH_JUMP:-}" ]] && ssh_args+=(-o "ProxyJump=${SSH_JUMP}")

# Anything else the caller wants, word-split the way a shell would.
if [[ -n "${SSH_OPTS:-}" ]]; then
  read -r -a extra_opts <<<"${SSH_OPTS}"
  ssh_args+=("${extra_opts[@]}")
fi

run() {
  if [[ -n "${DRY_RUN:-}" ]]; then
    printf '    '; printf '%q ' "$@"; printf '\n'
  else
    "$@"
  fi
}

echo "==> copying $(basename "${SCRIPT_DIR}")/ to ${TARGET}:${REMOTE_DIR}"
[[ -n "${SSH_JUMP:-}" ]] && echo "    through ${SSH_JUMP}"
run ssh "${ssh_args[@]}" "${TARGET}" "mkdir -p '${REMOTE_DIR}'"
# "/." rather than a trailing slash: otherwise scp nests the directory on re-runs
run scp "${ssh_args[@]}" -r "${SCRIPT_DIR}/." "${TARGET}:${REMOTE_DIR}/"

echo "==> running install-vm.sh on ${TARGET}"
if [[ -n "${KEYCLOAK_CLIENT_SECRET:-}" ]]; then
  # the secret travels over the ssh channel on stdin, so it never appears in the
  # VM's process list the way a command-line argument would
  if [[ -n "${DRY_RUN:-}" ]]; then
    run ssh "${ssh_args[@]}" "${TARGET}" "read -r s; cd '${REMOTE_DIR}' && ... (secret on stdin)"
  else
    printf '%s' "${KEYCLOAK_CLIENT_SECRET}" | ssh "${ssh_args[@]}" "${TARGET}" \
      "read -r s; cd '${REMOTE_DIR}' && chmod +x install-vm.sh get-token.sh bin/hostinfo-plugin.sh && \
       sudo KEYCLOAK_CLIENT_SECRET=\"\$s\" ./install-vm.sh '${ENV_FILE}' $*"
  fi
else
  run ssh "${ssh_args[@]}" -t "${TARGET}" \
    "cd '${REMOTE_DIR}' && chmod +x install-vm.sh get-token.sh bin/hostinfo-plugin.sh && sudo ./install-vm.sh '${ENV_FILE}' $*"
fi
