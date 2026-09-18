# MS cluster: control plane side of VM onboarding

The same manifests as [../cp](../cp), customised for the MS environment where
Hydra issues the VM tokens. The VM side is [../ms-vm](../ms-vm).

| File | What it does |
| --- | --- |
| `00-namespace.yaml` | the namespace the VM workloads join (drop it if it already exists) |
| `01-cert.yaml` | serving certificate for the vmgateway (`vm-onboarding` secret) |
| `02-control-plane-patch.yaml` | onboarding endpoint, the plane UID, and Hydra as a trusted JWT issuer |
| `03-workload-group.yaml` | Service, ServiceAccount, a Kubernetes pod of the app, and the WorkloadGroup |
| `04-onboarding-policy.yaml` | which Hydra subjects may onboard |
| `05-sidecar.yaml` | sidecar configuration for VMs running without iptables |
| `install-ms-cp.sh` | renders and applies all of the above |
| `ms-cp.env` | every value the manifests are rendered with |

## Run it

```shell
vi ms-cp.env                      # context, endpoint, Hydra issuer and JWKS, subjects
./install-ms-cp.sh --dry-run      # show the rendered manifests, change nothing
./install-ms-cp.sh
```

After applying, the script waits for the TSB operator to hand the issuer to the
onboarding plane, and prints the plane's UID so you can compare it with the
audience the Hydra tokens carry.

## What differs from `../cp`

| | `cp` (sandbox) | `ms-cp` |
| --- | --- | --- |
| Issuer | Keycloak realm `tetrate` | `${HYDRA_ISSUER}`, Hydra |
| Subjects in the policy | Keycloak service-account UUIDs | SPIFFE IDs from the token's `sub` |
| Attributes | `custom_attributes` (region, datacenter) | none: the Hydra token has no attribute object |
| `tokenFields` | `attributes.jsonPath: .custom_attributes` | omitted |
| Values | hardcoded | every value comes from `ms-cp.env` |
| Namespace, app, group names | hardcoded `payments` | `APP_NAMESPACE`, `APP_NAME`, `WORKLOAD_GROUP_NAME` |

## The two values that must agree

**1. The plane UID and the token audience.** Hydra mints the token for the URL
passed on its command line:

```shell
hydra -e dev service token https://vmgateway.istio-system.rcb.use.k8s.az-dev.ms.com
```

so `spec.meshExpansion.onboarding.uid` is set to `https://${VM_ENDPOINT}`. If
they differ, the plane rejects every token, and the plugin says so:

```
the issuer minted a token with the audience "…", while the Workload Onboarding
Plane expects the audience "…"
```

**2. The issuer string.** `${HYDRA_ISSUER}` must equal the token's `iss` exactly,
including the scheme and with no trailing slash.

## Things to confirm on the MS cluster

* **The cluster must reach `HYDRA_JWKS_URI`.** The value in `ms-cp.env` comes
  from the issuer's own discovery document:
  ```shell
  curl -s https://hydra-test.ms.com/.well-known/openid-configuration
  # {"issuer":"https://hydra-test.ms.com","token_endpoint":"https://hydra-test.ms.com/v1/token",
  #  "jwks_uri":"https://hydra-test.ms.com/.well-known/jwks",
  #  "id_token_signing_alg_values_supported":["RS256"]}
  ```
  The onboarding plane fetches that URL itself. If the cluster cannot reach it,
  replace `jwksUri` with an inline `jwks` document holding the keys.
* **`01-cert.yaml` uses the sandbox's `selfsigned-ca` ClusterIssuer.** With a
  certificate from the corporate CA, the VMs can drop `insecureSkipVerify`.
* **The subject is a SPIFFE ID**, and TSB builds the WorkloadEntry name from the
  subject. Watch the first onboarding for a name error:
  ```shell
  kubectl -n istio-system logs deploy/onboarding-plane -f | grep -E 'authenticated a workload|denied|invalid'
  ```
* **`03-workload-group.yaml` pulls `docker.io/nacx/obs-tester-server:2.0`.**
  Mirror it into the MS registry, or drop the Deployment and keep only the
  Service, ServiceAccount and WorkloadGroup.

Nothing here has been applied to an MS cluster. The manifests were rendered and
checked as valid YAML locally.
