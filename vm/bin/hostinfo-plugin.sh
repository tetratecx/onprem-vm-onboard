#!/usr/bin/env bash
#
# Workload Onboarding Agent HostInfo plugin for AWS, GCP and Azure.
#
# Reports the host's addresses to the agent: the private address as VPC and, when
# the instance has one, the public address as INTERNET.
#
# This exists because the agent's built-in "basic" hostinfo only enumerates local
# network interfaces - and on all three clouds a public address is NAT'd to the
# instance, never configured on an interface. Without this plugin a workload
# registered with connectedOver INTERNET has no public address to advertise, so
# the WorkloadEntry carries the private one and the cluster cannot reach it.
#
# Wired in by templates/agent.config.yaml.tmpl as:
#
#   host:
#     custom:
#       hostinfo:
#         plugin:
#           name: hostinfo
#           path: /usr/local/bin/onboarding-agent-hostinfo-plugin
#
# Plugin contract (see onboarding-agent-plugin-sdk):
#   - the request arrives as JSON on stdin; RPC_METHOD_NAME names the call
#   - success: the response JSON on stdout, exit 0
#   - failure: a google.rpc.Status JSON on stdout, exit 1
#   - diagnostics go to stderr, which the agent logs
#
# Response shape:
#   {"host":{"addresses":[{"ip":"10.0.0.4","type":"VPC"},
#                         {"ip":"52.1.2.3","type":"INTERNET"}]}}
#
# Overrides, for a host whose metadata service is unavailable or wrong. Set them
# through plugin.env in the agent configuration:
#   VPC_IP, INTERNET_IP
#
# Outside the agent it can be run by hand to see what it would report:
#   onboarding-agent-hostinfo-plugin --print    the addresses, as JSON
#   onboarding-agent-hostinfo-plugin --type     INTERNET or VPC
#   onboarding-agent-hostinfo-plugin --cloud    the detected platform
set -uo pipefail

log()  { echo "[hostinfo] $*" >&2; }
fail() { printf '{"code":%d,"message":"%s"}\n' "$1" "$2"; exit 1; }

CURL=(curl -s -f --noproxy '*' --connect-timeout 2 -m 5)

# A shape check alone would accept 999.1.1.1, and the onboarding plane validates
# the address properly - so reject anything out of range here, where the error
# can still be logged usefully.
is_ipv4() {
  local ip="${1:-}" o
  [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1:4}"; do
    ((10#${o} <= 255)) || return 1
  done
  return 0
}

# --- which cloud is this? ----------------------------------------------------
# DMI first: it is a local file read, so it costs nothing and cannot hang. The
# metadata probes are the fallback for hosts with unhelpful DMI strings.
detect_cloud() {
  local vendor=""
  for f in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name \
           /sys/class/dmi/id/bios_vendor /sys/class/dmi/id/chassis_asset_tag; do
    [[ -r "${f}" ]] && vendor+="$(tr -d '\0' <"${f}" 2>/dev/null) "
  done

  case "${vendor}" in
    *Amazon*|*amazon*|*EC2*)         echo aws;   return ;;
    *Google*|*google*)               echo gcp;   return ;;
    *Microsoft*|*microsoft*|*Hyper-V*|*7783-7084-3265-9085-8269-3286-77*)
                                     echo azure; return ;;
  esac

  # DMI was inconclusive - ask the metadata services, cheapest first.
  if "${CURL[@]}" -H 'Metadata-Flavor: Google' \
       http://metadata.google.internal/computeMetadata/v1/ >/dev/null 2>&1; then
    echo gcp; return
  fi
  if "${CURL[@]}" -H 'Metadata: true' \
       "http://169.254.169.254/metadata/instance?api-version=2021-02-01" >/dev/null 2>&1; then
    echo azure; return
  fi
  if "${CURL[@]}" -X PUT http://169.254.169.254/latest/api/token \
       -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' >/dev/null 2>&1 \
     || "${CURL[@]}" http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1; then
    echo aws; return
  fi

  echo unknown
}

# --- per-cloud metadata lookups ----------------------------------------------
# Each sets VPC_IP / INTERNET_IP if it can; a missing public address is normal
# for an instance in a private subnet and is not an error.

read_aws() {
  local imds=http://169.254.169.254/latest token
  # IMDSv2 first; fall back to v1 for instances that still allow it.
  token="$("${CURL[@]}" -X PUT "${imds}/api/token" \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  local -a hdr=()
  [[ -n "${token}" ]] && hdr=(-H "X-aws-ec2-metadata-token: ${token}")

  : "${VPC_IP:=$("${CURL[@]}" "${hdr[@]}" "${imds}/meta-data/local-ipv4" 2>/dev/null || true)}"
  : "${INTERNET_IP:=$("${CURL[@]}" "${hdr[@]}" "${imds}/meta-data/public-ipv4" 2>/dev/null || true)}"
}

read_gcp() {
  local md=http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0
  local -a hdr=(-H 'Metadata-Flavor: Google')

  : "${VPC_IP:=$("${CURL[@]}" "${hdr[@]}" "${md}/ip" 2>/dev/null || true)}"
  # No access-configs means no external address: a private instance whose egress
  # goes through Cloud NAT. The 404 is expected, hence the discarded error.
  : "${INTERNET_IP:=$("${CURL[@]}" "${hdr[@]}" "${md}/access-configs/0/external-ip" 2>/dev/null || true)}"
}

read_azure() {
  local md="http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0"
  local api="api-version=2021-02-01&format=text"
  local -a hdr=(-H 'Metadata: true')

  : "${VPC_IP:=$("${CURL[@]}" "${hdr[@]}" "${md}/privateIpAddress?${api}" 2>/dev/null || true)}"
  # Azure returns an empty string rather than a 404 when there is no public IP.
  : "${INTERNET_IP:=$("${CURL[@]}" "${hdr[@]}" "${md}/publicIpAddress?${api}" 2>/dev/null || true)}"

  # The network-interface metadata above only ever reports a *Basic* SKU public
  # IP. A Standard SKU address - the default for anything created today, and
  # what this repo's Terraform creates - is exposed solely under the
  # loadbalancer metadata, even when no load balancer sits in front of the VM.
  #
  # That endpoint has no per-field access (format=text 404s on its children), so
  # its JSON is parsed here. Splitting on commas first lets one sed handle both
  # the compact and the pretty-printed form.
  #
  # On a VM with no public address of its own it answers with an error object
  # and no frontendIpAddress, so nothing is picked up - and notably it does not
  # report the subnet's NAT gateway address, which would be wrong: outbound NAT
  # gives no inbound path, so advertising it as INTERNET would send the mesh to
  # an address that cannot answer.
  if [[ -z "${INTERNET_IP}" ]]; then
    INTERNET_IP="$("${CURL[@]}" "${hdr[@]}" \
      "http://169.254.169.254/metadata/loadbalancer?api-version=2020-10-01" 2>/dev/null \
      | tr ',' '\n' \
      | sed -n 's/.*"frontendIpAddress"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -1 || true)"
    [[ -n "${INTERNET_IP}" ]] && log "public address came from the loadbalancer metadata (Standard SKU)"
  fi
}

# Last resort, and what the agent's "basic" mode would have given: the first
# routable address on a local interface. Only ever a VPC address.
read_fallback() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  elif command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  : "${VPC_IP:=${ip}}"
}

# --- gather ------------------------------------------------------------------
VPC_IP="${VPC_IP:-}"
INTERNET_IP="${INTERNET_IP:-}"

CLOUD="$(detect_cloud)"
case "${CLOUD}" in
  aws)   read_aws ;;
  gcp)   read_gcp ;;
  azure) read_azure ;;
  *)     log "could not identify the cloud platform; using the local interface address" ;;
esac

# Discard anything unusable *before* the fallback runs, so a bad override or a
# metadata service answering with an error page does not suppress it.
if [[ -n "${VPC_IP}" ]] && ! is_ipv4 "${VPC_IP}"; then
  log "ignoring VPC address \"${VPC_IP}\": not a valid IPv4 address"
  VPC_IP=""
fi
if [[ -n "${INTERNET_IP}" ]] && ! is_ipv4 "${INTERNET_IP}"; then
  log "ignoring INTERNET address \"${INTERNET_IP}\": not a valid IPv4 address"
  INTERNET_IP=""
fi

read_fallback
is_ipv4 "${VPC_IP}" || VPC_IP=""

# --- modes for running it by hand --------------------------------------------
case "${1:-}" in
  --cloud) echo "${CLOUD}"; exit 0 ;;
  --type)
    # Which connectedOver value suits this host: a public address means the
    # cluster can reach it over the internet.
    [[ -n "${INTERNET_IP}" ]] && echo INTERNET || echo VPC
    exit 0
    ;;
  --print)
    printf 'cloud=%s\nVPC=%s\nINTERNET=%s\n' \
      "${CLOUD}" "${VPC_IP:-none}" "${INTERNET_IP:-none}"
    exit 0
    ;;
  -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac

# --- the plugin call ---------------------------------------------------------
cat >/dev/null   # consume the GetHostInfoRequest, which carries no fields

if [[ "${RPC_METHOD_NAME:-}" != "GetHostInfo" ]]; then
  # UNIMPLEMENTED
  fail 12 "unsupported method: ${RPC_SERVICE_NAME:-?}/${RPC_METHOD_NAME:-?}"
fi

ADDRS=()
[[ -n "${VPC_IP}" ]]      && ADDRS+=("{\"ip\":\"${VPC_IP}\",\"type\":\"VPC\"}")
[[ -n "${INTERNET_IP}" ]] && ADDRS+=("{\"ip\":\"${INTERNET_IP}\",\"type\":\"INTERNET\"}")

if [[ ${#ADDRS[@]} -eq 0 ]]; then
  # UNAVAILABLE - the agent retries, which covers a metadata service that is
  # briefly unreachable during boot.
  fail 14 "could not determine any address for this host (cloud=${CLOUD})"
fi

( IFS=,; printf '{"host":{"addresses":[%s]}}\n' "${ADDRS[*]}" )
log "cloud=${CLOUD} VPC=${VPC_IP:-none} INTERNET=${INTERNET_IP:-none}"
exit 0
