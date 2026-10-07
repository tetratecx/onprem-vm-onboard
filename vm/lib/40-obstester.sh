# Step 4 (optional): the obs-tester demo workload behind the sidecar.
#
# Any process listening on 127.0.0.1:8000 works just as well - this is only here
# so that a freshly onboarded VM actually serves traffic and can be tested from
# the cluster. Set INSTALL_OBSTESTER="false" when the real application is already
# on the VM.

step_obstester() {
  if [[ "${INSTALL_OBSTESTER}" != "true" ]]; then
    info "INSTALL_OBSTESTER is not \"true\", skipping the demo app"
    return 0
  fi

  log "Installing the obs-tester demo service"

  # the configured path first, then the places the binary tends to be copied to
  # by hand on an existing VM
  local src c found=""
  src="$(resolve_path "${OBSTESTER_SOURCE}")"
  local candidates=("${src}" /opt/ots-linux-x86_64 ~/ots-linux-x86_64)
  for c in "${candidates[@]}"; do
    if [[ -f "${c}" ]]; then found="${c}"; break; fi
  done

  if [[ -n "${found}" ]]; then
    install -m 0755 "${found}" "${OBSTESTER_PATH}"
    info "installed ${OBSTESTER_PATH} from ${found}"
  elif [[ -x "${OBSTESTER_PATH}" ]]; then
    info "using the ots binary already at ${OBSTESTER_PATH}"
  else
    warn "no ots binary found (looked in: ${candidates[*]}); skipping the demo app."
    warn "Put it in vm/bin/ots-linux-x86_64 so push-to-vm.sh carries it to the VM."
    INSTALL_OBSTESTER="false"
    return 0
  fi

  # The sidecar binds its egress listeners on 127.0.0.2 (05-sidecar.yaml), so
  # these names have to resolve there for the demo's outbound calls to be
  # captured by the mesh.
  local host
  for host in ${OBSTESTER_HOSTS}; do
    if grep -qE "^127\.0\.0\.2[[:space:]]+${host}\b" /etc/hosts; then
      info "/etc/hosts already maps ${host}"
    else
      printf '127.0.0.2 %s\n' "${host}" >>/etc/hosts
      info "added ${host} to /etc/hosts"
    fi
  done

  write_template "${SCRIPT_DIR}/templates/obstester.service.tmpl" \
    /etc/systemd/system/obstester.service 0644 && OBSTESTER_CHANGED=1

  return 0
}
