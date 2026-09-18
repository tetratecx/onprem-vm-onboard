#!/usr/bin/env bash
#
# Finds out what "module load cloud/hydra/dev" actually sets up, and where the
# hydra CLI gets its credentials from.
#
# This matters because hydra-token-shim runs hydra from systemd, not from your
# interactive shell. Anything that comes from your login session - a Kerberos
# ticket, an ssh-agent, a token cached in your home directory - is present when
# you run the command by hand and may be missing or expired under systemd.
#
# Run it on the VM, as the user that runs hydra successfully (HYDRA_USER):
#
#   ./diagnose-hydra.sh > hydra-report.txt 2>&1
#
# Values of variables whose names look secret are masked, so the output can be
# shared. Read it before pasting it anywhere.
set -uo pipefail

MODULE="${1:-cloud/hydra/dev}"

section() { printf '\n========== %s ==========\n' "$*"; }
note()    { printf '  %s\n' "$*"; }

# print "NAME=value", masking values of variables that look like credentials
print_env_line() {
  local line="$1" name="${1%%=*}"
  case "${name}" in
    *SECRET*|*TOKEN*|*PASSWORD*|*PASSWD*|*KEY*|*CRED*|*COOKIE*|*SESSION*)
      printf '  %s=<set, %d chars, masked>\n' "${name}" "$(( ${#line} - ${#name} - 1 ))" ;;
    *) printf '  %s\n' "${line}" ;;
  esac
}

section "who and where"
note "user:  $(id -un) (uid $(id -u))"
note "host:  $(hostname -f 2>/dev/null || hostname)"
note "shell: ${SHELL:-unknown}"
note "date:  $(date -u +%FT%TZ)"

section "is the module system available?"
if type module >/dev/null 2>&1; then
  note "module is a $(type -t module)"
  note "MODULEPATH=${MODULEPATH:-<unset>}"
  note "LMOD_CMD=${LMOD_CMD:-<unset>}  MODULESHOME=${MODULESHOME:-<unset>}"
else
  note "no 'module' command in this shell."
  note "It is usually defined by /etc/profile.d/modules.sh or lmod.sh, which is why"
  note "the shim runs the command through 'bash -lc' (a login shell)."
fi

section "what the modulefile does: module show ${MODULE}"
# the modulefile lists every setenv / prepend-path: this is the whole environment
bash -lc "module show ${MODULE}" 2>&1 | sed 's/^/  /'

section "the environment the module adds"
before="$(mktemp)"; after="$(mktemp)"
bash -lc 'env' 2>/dev/null | sort >"${before}"
bash -lc "module load ${MODULE} >/dev/null 2>&1; env" 2>/dev/null | sort >"${after}"
if diff -q "${before}" "${after}" >/dev/null; then
  note "the module changed nothing in the environment (or it failed to load)"
else
  while IFS= read -r line; do
    case "${line}" in
      ">"*) print_env_line "${line#> }" ;;
    esac
  done < <(diff "${before}" "${after}")
fi
rm -f "${before}" "${after}"

section "the hydra command itself"
bash -lc "module load ${MODULE} >/dev/null 2>&1
  p=\$(command -v hydra || true)
  if [[ -z \"\${p}\" ]]; then echo '  hydra not found after loading the module'; exit 0; fi
  echo \"  path:  \${p}\"
  echo \"  type:  \$(file -b \"\${p}\" 2>/dev/null)\"
  echo \"  links: \$(readlink -f \"\${p}\")\"
  # a wrapper script would show how it authenticates
  if head -c 2 \"\${p}\" | grep -q '#!'; then
    echo '  --- it is a script, first 60 lines:'
    sed -n '1,60p' \"\${p}\" | sed 's/^/    /'
  fi"

section "hydra's own idea of credentials"
bash -lc "module load ${MODULE} >/dev/null 2>&1
  hydra --help 2>&1 | sed -n '1,40p' | sed 's/^/  /'
  echo '  --- service token --help:'
  hydra -e dev service token --help 2>&1 | sed -n '1,40p' | sed 's/^/    /'"

section "Kerberos"
if command -v klist >/dev/null 2>&1; then
  klist 2>&1 | sed 's/^/  /'
  note "KRB5CCNAME=${KRB5CCNAME:-<unset>}"
  note "a ticket cache tied to your login session is NOT available to a systemd service;"
  note "a keytab (KRB5_CLIENT_KTNAME) or a machine credential is."
else
  note "no klist: Kerberos is probably not how hydra authenticates"
fi

section "credential files in the usual places"
for d in ~/.hydra ~/.config/hydra ~/.ms ~/.config/ms /etc/hydra /etc/ms /var/lib/hydra; do
  if [[ -e "${d}" ]]; then
    note "${d}:"
    ls -la "${d}" 2>/dev/null | sed 's/^/    /'
  fi
done
for f in ~/.netrc ~/.k5login /etc/krb5.keytab; do
  [[ -e "${f}" ]] && note "$(ls -la "${f}")"
done

section "does it work without your login session?"
note "This is the question that decides how the shim must run."
note "Compare these two:"
note ""
note "  # as you do now, in your interactive session"
note "  hydra -e dev service token https://<vm-endpoint> | cut -d. -f2 | base64 -d | jq .exp"
note ""
note "  # the way systemd will run it: no tty, no inherited session"
note "  sudo systemd-run --uid=\$(id -un) --pipe --wait --quiet \\"
note "     bash -lc 'module load ${MODULE}; hydra -e dev service token https://<vm-endpoint>'"
note ""
note "If the first works and the second does not, hydra depends on something your"
note "login gives it. Look at what the sections above found: a Kerberos ticket"
note "(needs a keytab for a service), a file under your home directory (make sure"
note "the shim runs as that same user), or a variable the module does not set."
