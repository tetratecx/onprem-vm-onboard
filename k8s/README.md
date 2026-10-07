# Control plane side of VM onboarding

Run once per cluster. This prepares the cluster that hosts the TSB Workload
Onboarding Plane to accept VMs presenting Keycloak-issued JWTs.

The VM side is [`../vm`](../vm); the overall walkthrough is in the
[top-level README](../README.md).

| File | What it does |
| --- | --- |
| `install-cp.sh` | renders and applies everything below, then verifies the result |
| `cp.env` | every value the manifests are rendered with |
| `00-namespace.yaml` | the namespace the VM workloads join |
| `01-cert.yaml` | serving certificate for the vmgateway (the `vm-onboarding` secret) |
| `02-control-plane-patch.yaml` | onboarding endpoint, the plane UID, and Keycloak as a trusted JWT issuer |
| `03-workload-group.yaml` | Service, ServiceAccount and the WorkloadGroup the VMs join |
| `04-onboarding-policy.yaml` | which tokens are allowed to onboard |
| `05-sidecar.yaml` | sidecar configuration for VMs running without iptables |
| `keycloak/` | creating the VM client and its audience mapper |

## Run it

```shell
cp cp.env cp.env.local
vi cp.env.local                        # context, endpoint, realm URL, subjects
./install-cp.sh cp.env.local --dry-run # render and print, change nothing
./install-cp.sh cp.env.local
```

Everything is rendered with `envsubst`, so `--dry-run` shows exactly what will be
applied. Re-running is safe: the manifests are applied with `kubectl apply` and
the `ControlPlane` is patched with `--type=merge`, never replaced.

Afterwards the script:

1. waits up to two minutes for the TSB operator to copy the issuer from the
   `ControlPlane` into the `OnboardingPlane` resource the plane actually reads;
2. prints the **plane UID**, and warns if it is not `https://${VM_ENDPOINT}`;
3. prints the **vmgateway LoadBalancer address** for the DNS record.

## Settings

All in `cp.env`:

| Variable | Meaning |
| --- | --- |
| `CLUSTER_KUBECONTEXT` | kubectl context of the cluster hosting the onboarding plane |
| `VM_ENDPOINT` | vmgateway hostname; the plane UID is derived from it as `https://<it>` |
| `INSTALL_CERT` | `false` if the `vm-onboarding` TLS secret is created elsewhere |
| `CERT_ISSUER_NAME` / `_KIND` | cert-manager issuer for that certificate |
| `KEYCLOAK_REALM_URL` | the realm URL; this is exactly the token's `iss` |
| `KEYCLOAK_SHORT_NAME` | issuer alias; appears in the WorkloadEntry name |
| `APP_NAMESPACE` / `APP_NAME` / `WORKLOAD_GROUP_NAME` | the workload the VMs join |
| `ALLOWED_SUBJECTS` | the `sub` claims permitted to onboard, space separated |
| `ALLOWED_ATTRIBUTES` | `name=value` pairs matched against `custom_attributes`; empty to skip |

`ALLOWED_ATTRIBUTES` groups repeated names, so
`"region=uscentral1 region=useast1"` renders one `region` entry allowing either
value.

## What the ControlPlane patch sets, and why it matters

```yaml
spec:
  meshExpansion:
    onboarding:
      endpoint:
        hosts: [ "${VM_ENDPOINT}" ]     # where the VMs connect
        secretName: vm-onboarding       # the certificate they are served
      uid: https://${VM_ENDPOINT}       # must be in the token's 'aud'
      workloads:
        authentication:
          jwt:
            issuers:
            - issuer: ${KEYCLOAK_ISSUER}    # must equal the token's 'iss'
              shortName: ${KEYCLOAK_SHORT_NAME}
              jwksUri: ${KEYCLOAK_JWKS_URI} # fetched by the plane itself
              tokenFields:
                attributes:
                  jsonPath: .custom_attributes
```

**The plane UID.** The onboarding plane rejects any token whose `aud` does not
contain its own UID. Setting it to `https://${VM_ENDPOINT}` makes it a stable,
readable value, but Keycloak has to be told to put it in the token - see
[`keycloak/`](keycloak/). Read the live value with:

```shell
kubectl -n istio-system get cm onboarding-plane-config \
  -o jsonpath='{.data.config\.yaml}' | grep uid
```

**The issuer string** must equal the token's `iss` exactly - same scheme, no
trailing slash. `install-cp.sh` strips a trailing slash for you.

**`tokenFields.attributes`** tells the plane where the workload attributes live.
Note that `tokenFields.subject` is deliberately *not* set: it is stripped from
the `ControlPlane` before reaching the `OnboardingPlane`, so the subject an
`OnboardingPolicy` matches is always the `sub` claim. For a `client_credentials`
token that is **the UUID of the client's service account**, not the client name -
which is why `ALLOWED_SUBJECTS` holds UUIDs. Read it from a real token:

```shell
cd ../vm && sudo ./get-token.sh --decode | grep '"sub"'
```

## If the cluster cannot reach Keycloak

The plane fetches `jwksUri` itself. In a segmented network, embed the keys
instead of fetching them: replace `jwksUri` in `02-control-plane-patch.yaml` with
an inline `jwks` document.

```shell
# render the whole issuer stanza from the live realm, including the JWKS
cd ../vm
set -a; . ./ext-jwt.env; set +a
onboarding-agent-ext-jwt-credential-plugin issuer-config \
  --short-name keycloak --attributes-path .custom_attributes
```

An embedded JWKS has to be re-rendered whenever the realm's signing keys change
(for instance after the Keycloak database is wiped and the realm recreated).

## Verify

```shell
# the issuer reached the onboarding plane
kubectl -n istio-system get onboardingplane onboarding-plane \
  -o jsonpath='{.spec.workloads.authentication.jwt.issuers[*].issuer}'

# the vmgateway has an address for the DNS record
kubectl -n istio-system get svc vmgateway

# watch VMs onboard, admitted or denied, with the reason
kubectl -n istio-system logs deploy/onboarding-plane -f \
  | grep -E 'authenticated a workload|denied|invalid'

# one entry per onboarded VM
kubectl -n payments get workloadentry
```

## Notes before a production run

* **The certificate.** `01-cert.yaml` defaults to the sandbox `selfsigned-ca`
  ClusterIssuer, which is why the VMs onboard with `insecureSkipVerify`. Point
  `CERT_ISSUER_NAME` at the corporate CA and set `ONBOARDING_TLS_INSECURE="false"`
  in `../vm/vm.env`.
* **DNS.** The `external-dns` annotation in the patch only does something if
  external-dns runs in the cluster. Otherwise create the record by hand.
* **The namespace.** `00-namespace.yaml` sets `istio-injection: enabled`, which
  matters only for pods of the same service; the VMs are unaffected. Delete the
  file if the namespace is managed elsewhere.
* **Scope of the policy.** `04-onboarding-policy.yaml` admits matching VMs into
  any WorkloadGroup labelled `app: ${APP_NAME}` in its namespace. Narrow
  `workloadGroupSelector` if you need a tighter grant.
