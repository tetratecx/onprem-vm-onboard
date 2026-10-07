# Step 1: install the Onboarding Agent and the Istio sidecar.
#
# Both packages are served by the vmgateway itself, at
#   https://${VM_ENDPOINT}/install/{deb,rpm}/{amd64,arm64}/<package>.<format>
# so the VM needs no access to any other repository.
#
# PKG_FORMAT, PKG_MANAGER and PKG_ARCH are detected in install-vm.sh.

# pkg_installed <name> - true when the package is already installed
pkg_installed() {
  case "${PKG_FORMAT}" in
    deb) dpkg -s "$1" >/dev/null 2>&1 ;;
    rpm) rpm -q "$1" >/dev/null 2>&1 ;;
  esac
}

# Extra flags for the rpm package managers, which refresh every enabled repo
# before installing even a local file.
#
# --disablerepo for the source and debug repos: they carry no binary packages, so
# they can never satisfy a dependency - they only add time and failure modes. The
# cloud RHEL images enable four of them, and the GCP RHUI mirrors regularly serve
# stale metadata for them (a 404 on appstream-source-rpms repodata), which aborts
# the whole transaction.
#
# skip_if_unavailable: one unreachable repo should not fail an install whose
# dependencies are satisfiable without it. If something genuinely needed is
# missing, dnf still fails - with a "nothing provides" error that names it,
# which is far clearer than a metadata download failure.
RPM_REPO_FLAGS=(
  --disablerepo='*-source-rpms'
  --disablerepo='*-debug-rpms'
  --setopt='*.skip_if_unavailable=1'
)

# pkg_install <file> [<file>...] - install local package files
pkg_install() {
  case "${PKG_MANAGER}" in
    apt)  apt-get install -y "$@" ;;
    # dnf/yum/zypper resolve the dependencies of a local file; 'rpm -i' does not
    dnf)  dnf install -y "${RPM_REPO_FLAGS[@]}" "$@" ;;
    yum)  yum install -y "${RPM_REPO_FLAGS[@]}" "$@" ;;
    zypper) zypper --non-interactive install --allow-unsigned-rpm "$@" ;;
    *)    die "no supported package manager found (apt-get, dnf, yum or zypper)" ;;
  esac
}

step_packages() {
  log "Installing the onboarding packages (${PKG_FORMAT}, ${PKG_ARCH})"

  if pkg_installed onboarding-agent && pkg_installed istio-sidecar; then
    info "onboarding-agent and istio-sidecar are already installed"
  else
    local base="https://${VM_ENDPOINT}/install/${PKG_FORMAT}/${PKG_ARCH}"
    local pkg file files=()
    for pkg in onboarding-agent istio-sidecar; do
      file="/opt/${pkg}.${PKG_FORMAT}"
      info "downloading ${pkg}.${PKG_FORMAT} from ${base}"
      # -k: at this point the VM does not yet trust the vmgateway certificate.
      # The retries cover a vmgateway whose DNS record was only just created.
      curl -k -fL --retry-all-errors --retry-delay 5 --retry 24 \
        -o "${file}" "${base}/${pkg}.${PKG_FORMAT}" \
        || die "failed to download ${base}/${pkg}.${PKG_FORMAT}
     Is ${VM_ENDPOINT} resolvable and reachable on 443 from this VM?
       getent hosts ${VM_ENDPOINT}
       curl -ksv https://${VM_ENDPOINT}/install/ 2>&1 | head"
      files+=("${file}")
    done
    pkg_install "${files[@]}"
  fi

  # Envoy needs this to bind privileged ports (port 80 for an egress listener).
  # Must happen before the agent starts the sidecar.
  if [[ -x /usr/local/bin/envoy ]]; then
    setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/envoy
    info "granted CAP_NET_BIND_SERVICE to /usr/local/bin/envoy"
  else
    warn "/usr/local/bin/envoy not found, skipping setcap"
  fi
}
