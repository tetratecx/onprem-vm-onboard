# VM side of the onboarding

Run once per VM. `install-vm.sh` turns a bare CentOS / RHEL / Rocky / Alma /
Ubuntu VM into a mesh workload that onboards into TSB with a Keycloak-issued JWT.

The control plane side is [`../k8s`](../k8s); the overall walkthrough is in the
[top-level README](../README.md).

```
vm/
├── install-vm.sh      entry point, run on the VM as root
├── push-to-vm.sh      copies this directory to a VM and runs the above
├── get-token.sh       fetch a token and validate its claims
├── vm.env             all settings (endpoint, workload group, Keycloak client)
├── ext-jwt.env        the same settings, for running the plugin by hand
├── bin/               the credential plugin, and the demo app binary
├── lib/
│   ├── common.sh      logging, template rendering, the plugin environment
│   ├── 10-packages.sh onboarding-agent + istio-sidecar (.rpm or .deb)
│   ├── 20-plugin.sh   the ext-jwt credential plugin and the client secret
│   ├── 30-config.sh   renders the two agent config files
│   ├── 40-obstester.sh the obs-tester demo service (optional)
│   └── 50-services.sh pre-flight credential check, then enable and restart
└── templates/         what gets rendered into /etc/onboarding-agent
```

## Before you start

On the cluster side, [`../k8s/install-cp.sh`](../k8s/install-cp.sh) must have run:
the trusted issuer, the `WorkloadGroup` and the `OnboardingPolicy` have to exist.
In Keycloak, the client needs an Audience mapper carrying the plane UID
([`../k8s/keycloak/add-audience.sh`](../k8s/keycloak/add-audience.sh)).

On the VM:

```shell
# RHEL / CentOS / Rocky / Alma
sudo dnf install -y curl gettext libcap       # yum on CentOS 7 / RHEL 7
# Ubuntu / Debian
sudo apt-get install -y curl gettext-base libcap2-bin
```

The VM needs outbound HTTPS to the vmgateway (`VM_ENDPOINT`) and to Keycloak.
Behind a proxy, set `HTTPS_PROXY` in the agent's environment.

`bin/` already holds the plugin binary built for `linux-amd64`. For an `arm64`
VM, build it for that architecture and replace the file.

## Run it

From your laptop - this copies the whole directory to the VM and runs the
installer there, so nothing has to be moved by hand:

```shell
KEYCLOAK_CLIENT_SECRET='<the client secret>' \
  SSH_KEY=~/.ssh/vm.pem ENV_FILE=vm.env.local \
  ./push-to-vm.sh ec2-user@<vm-ip>
```

To reach an instance in a private subnet, send it through the public mesh VM that
doubles as the jump host:

```shell
KEYCLOAK_CLIENT_SECRET='<the client secret>' \
  SSH_JUMP=ec2-user@<public-instance-ip> SSH_KEY=~/.ssh/vm.pem \
  ./push-to-vm.sh ec2-user@<private-instance-ip>
```

`push-to-vm.sh` reads `SSH_KEY` (identity file), `SSH_JUMP` (host to jump
through), `SSH_OPTS` (any further ssh/scp options) and `DRY_RUN=1` (print the
commands instead of running them). If you built the VMs with `terraform/`,
`./deploy.sh onboard` prints the whole command per instance.

Or on the VM itself:

```shell
sudo ./install-vm.sh                      # uses vm.env
sudo ./install-vm.sh vm.env.local         # or your own copy
sudo KEYCLOAK_CLIENT_SECRET='…' ./install-vm.sh vm.env.local
```

Passing the secret in the environment wins over the env file, so it never has to
be written to a file in git. Over SSH it travels on stdin, so it does not appear
in the VM's process list either.

Re-running is safe. Files are rewritten only when their content changes, and the
services restart only when something changed.

### What it does, in order

1. **packages** - downloads `onboarding-agent` and `istio-sidecar` from
   `https://${VM_ENDPOINT}/install/{rpm,deb}/{amd64,arm64}/` and installs them,
   then grants Envoy `CAP_NET_BIND_SERVICE` so it can bind privileged ports.
2. **plugin** - installs the credential plugin to `/usr/local/bin/` and writes the
   client secret to `/etc/onboarding-agent/client-secret`, mode `0600`, owned by
   the `onboarding-agent` user.
3. **config** - renders `/etc/onboarding-agent/agent.config.yaml` and
   `onboarding.config.yaml` from [`templates/`](templates/).
4. **demo app** - installs the obs-tester service on `127.0.0.1:8000` and maps the
   egress hostnames to `127.0.0.2` in `/etc/hosts` (skip with
   `INSTALL_OBSTESTER="false"`).
5. **check and start** - runs the plugin's `check` as the agent user, then enables
   and restarts the services. A failing check does not stop the install; the agent
   retries until the configuration is right.

## Settings

Everything lives in `vm.env`. The ones you are most likely to change:

| Variable | Meaning |
| --- | --- |
| `VM_ENDPOINT` | vmgateway hostname; packages and onboarding both go through it |
| `ONBOARDING_PLANE_UID` | must be in the token's `aud`; defaults to `https://${VM_ENDPOINT}` |
| `ONBOARDING_TLS_INSECURE` | `false` once the vmgateway certificate comes from a CA the VM trusts |
| `WORKLOAD_GROUP_NAMESPACE` / `_NAME` | the WorkloadGroup this VM joins |
| `CONNECTED_OVER` | `INTERNET` or `VPC` - which address the cluster will route to |
| `KEYCLOAK_REALM_URL` | the realm URL; the token and JWKS endpoints derive from it |
| `KEYCLOAK_CLIENT_ID` | the client this VM authenticates as |
| `KEYCLOAK_CLIENT_SECRET` | better passed in the environment than stored here |
| `KEYCLOAK_CA_FILE` | PEM bundle, if Keycloak uses a corporate CA |
| `INSTALL_OBSTESTER` | `true` installs a demo app behind the sidecar |

## How the agent reports this host's addresses

The onboarding plane needs to know which address to put in the `WorkloadEntry`,
and that depends on `CONNECTED_OVER`:

| `CONNECTED_OVER` | The cluster reaches this VM at |
| --- | --- |
| `auto` (default) | decided per host - `INTERNET` if the instance has a public address, `VPC` if not |
| `INTERNET` | its public address |
| `VPC` | its private address |

`auto` exists because the same env file is often used for instances in both
subnets, and a hardcoded `VPC` then quietly gives a public instance the wrong
address.

**`INTERNET` needs the HostInfo plugin.** The agent's built-in `basic` mode only
enumerates local network interfaces, and on AWS, GCP and Azure a public address
is NAT'd to the instance - it never appears on an interface. Without the plugin
there is simply no public address for the agent to advertise.

`bin/hostinfo-plugin.sh` covers all three clouds: it detects the platform from
DMI (falling back to probing the metadata services), reads the private and
public addresses, and reports them as `VPC` and `INTERNET`. It is installed to
`/usr/local/bin/onboarding-agent-hostinfo-plugin` and wired in as:

```yaml
host:
  custom:
    hostinfo:
      plugin:
        name: hostinfo
        path: /usr/local/bin/onboarding-agent-hostinfo-plugin
```

Run it by hand to see what it will report:

```shell
onboarding-agent-hostinfo-plugin --print   # cloud, VPC and INTERNET addresses
onboarding-agent-hostinfo-plugin --type    # the connectedOver value it implies
onboarding-agent-hostinfo-plugin --cloud   # aws | gcp | azure | unknown
```

`HOSTINFO_MODE` selects between `plugin` (the default), `basic` (the agent's
interface scan - private addresses only) and `default` (no stanza at all, the
agent decides). Set `VPC_IP` / `INTERNET_IP` in the environment to override what
the plugin reports, for a host whose metadata service is blocked.

### Where each cloud hides the public address

| Cloud | Private | Public |
| --- | --- | --- |
| AWS | IMDSv2 `meta-data/local-ipv4` | `meta-data/public-ipv4` |
| GCP | `network-interfaces/0/ip` | `network-interfaces/0/access-configs/0/external-ip` |
| Azure | `instance/network/.../privateIpAddress` | **`metadata/loadbalancer`**, not the interface metadata |

Azure is the awkward one. Its instance metadata only ever reports a **Basic SKU**
public IP under the network interface; a **Standard SKU** address - the default
for anything created today, and what `terraform/` creates - leaves that field an
empty string. Standard addresses are published under the *loadbalancer* metadata
instead, even when no load balancer is in front of the VM:

```shell
curl -s -H 'Metadata: true' \
  'http://169.254.169.254/metadata/loadbalancer?api-version=2020-10-01'
# {"loadbalancer":{"publicIpAddresses":[{"frontendIpAddress":"20.172.172.101", ...
```

The plugin tries the interface metadata first and falls back to this. Two things
make the fallback safe rather than a guess: that endpoint has no per-field
access, so the JSON is parsed; and on a VM with no public address of its own it
returns an error object rather than the subnet's NAT gateway address - which
would be actively wrong, since outbound NAT gives the mesh no way back in.

## One Keycloak client per VM

The plane derives the `WorkloadEntry` name from the token's subject:

```
payments-v1-jwt-keycloak--<sub>
```

For a `client_credentials` token `sub` is the **service account UUID of the
Keycloak client**, which is the same for every VM sharing that client. Two VMs on
one client therefore produce the *same* `WorkloadEntry` name and overwrite each
other's address - whichever onboarded last wins, and the mesh sees one endpoint
that flips on every agent restart.

So give each VM its own client:

```shell
cd ../k8s/keycloak
./add-client.sh --client-id vm-gcp-public-1 --secret '...' --plane-uid '<uid>'
./add-client.sh --client-id vm-gcp-private-1 --secret '...' --plane-uid '<uid>'
```

then set `KEYCLOAK_CLIENT_ID` (and the secret) per VM, and add each new `sub` to
`ALLOWED_SUBJECTS` in `../k8s/cp.env`. Sharing a client is fine only when the VMs
are meant to be interchangeable replicas *and* you do not need them as separate
endpoints.

## Check the token without changing anything

```shell
sudo ./get-token.sh --decode    # claims, plus the checks the plane applies
sudo ./get-token.sh --check     # the plugin's own end-to-end report
sudo ./get-token.sh --curl      # print the equivalent curl command, run nothing
sudo ./install-vm.sh --check-only
```

`--decode` does a plain `client_credentials` POST and reports `iss`, `aud`, `sub`
and `exp`, ending with exactly what `../k8s/cp.env` must contain. `--check` runs
the plugin, which additionally verifies the RS256 signature against the realm's
JWKS. Both exit non-zero if the VM could not onboard with that token.

The most common failure is the `aud` check: the Keycloak client is missing its
Audience mapper for the plane UID. Fix it from the cluster side with
`../k8s/keycloak/add-audience.sh <plane-uid>`, then clear the cache:

```shell
sudo rm -f /var/lib/onboarding-agent/ext-jwt-credential.cache
sudo systemctl restart onboarding-agent
```

To run the plugin's subcommands directly:

```shell
set -a; . ./ext-jwt.env; set +a
onboarding-agent-ext-jwt-credential-plugin token --audience <plane-uid> --output json
onboarding-agent-ext-jwt-credential-plugin issuer-config --short-name keycloak
```

## Linux flavors

The package format is picked from the package manager present:

| VM | Format | Installed with |
| --- | --- | --- |
| RHEL, CentOS, Rocky, Alma, Amazon Linux, Fedora | `.rpm` | `dnf` or `yum` |
| SUSE, openSUSE | `.rpm` | `zypper --allow-unsigned-rpm` |
| Ubuntu, Debian | `.deb` | `apt-get` |

The architecture comes from `uname -m`, mapped to what the vmgateway publishes
(`amd64` for `x86_64`, `arm64` for `aarch64`). The plugin binary in `bin/` must
match.

On RHEL and CentOS nothing needs an SELinux policy change - the agent, Envoy and
the plugin all run from standard paths. firewalld does not block the outbound
connections these use, and the app listens on `127.0.0.1` with all inbound
traffic arriving through the sidecar, so no port needs opening.

## Afterwards

```shell
journalctl -u onboarding-agent -f          # on the VM
kubectl -n payments get workloadentry      # on the cluster
```

An entry named `payments-v1-jwt-keycloak--<sub>` means the VM is onboarded:
the WorkloadGroup, the issuer short name, and the token's subject. `<sub>` is the
Keycloak service-account UUID, which is what the `OnboardingPolicy` matches on.

Useful local state:

| Path | What it is |
| --- | --- |
| `/etc/onboarding-agent/agent.config.yaml` | how the credential is obtained |
| `/etc/onboarding-agent/onboarding.config.yaml` | where it onboards, and to which group |
| `/etc/onboarding-agent/client-secret` | the Keycloak client secret, `0600` |
| `/var/lib/onboarding-agent/ext-jwt-credential.cache` | the cached token, `0700` dir |

## What it does not do

* It does not create the Keycloak client or its mappers - see
  [`../k8s/keycloak/`](../k8s/keycloak/).
* It does not configure the cluster - see [`../k8s/`](../k8s/).
* It does not install `curl`, `envsubst` (gettext) or `setcap` (libcap); it tells
  you the command to install them if one is missing.
