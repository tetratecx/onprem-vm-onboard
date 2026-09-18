# MS VM: onboarding with a Hydra-issued JWT

On the MS VMs the token already exists. Hydra mints it from the command line:

```shell
module load cloud/hydra/dev
hydra -e dev service token https://vmgateway.istio-system.rcb.use.k8s.az-dev.ms.com
```

```json
{
  "sub": "spiffe://hydra-test.ms.com/ms/user/nizam",
  "aud": "https://vmgateway.istio-system.rcb.use.k8s.az-dev.ms.com",
  "iss": "https://hydra-test.ms.com",
  "exp": "1 hour after iat"
}
```

That token already has everything the Workload Onboarding Plane requires: a
subject, the plane's own URL as the audience, and an issuer the ControlPlane can
be told to trust.

## The problem, and the shim

The External JWT Credential Plugin speaks OAuth 2.0: it POSTs to a token endpoint
and reads a JSON token response. It has no "run this command" mode. Hydra is a
CLI and has no token endpoint.

`hydra-token-shim.py` bridges the gap. It is an OAuth 2.0 token endpoint on
127.0.0.1 that runs the Hydra command and wraps the result in a token response:

```
Onboarding Agent
   │  GetCredential(audience = https://vmgateway.../)
   ▼
ext-jwt-credential plugin
   │  POST http://127.0.0.1:9099/token   grant_type=client_credentials&audience=…
   ▼
hydra-token-shim (systemd, runs as the Hydra user)
   │  bash -lc 'module load cloud/hydra/dev; hydra -e dev service token <audience>'
   ▼
{"access_token": "<the Hydra token>", "token_type": "Bearer", "expires_in": 3597}
```

The plugin and the agent are used unmodified. The audience the agent asks for is
passed straight through to the Hydra command, so the token is always minted for
the plane the VM is onboarding to.

The shim also:

* **caches** a token per audience until shortly before `exp`, so Hydra is not run
  on every credential request;
* **reads `exp`** from the token and reports it as `expires_in`, so the agent
  renews at the right time;
* **requires a `client_secret`** (a random secret generated at install time,
  readable only by the agent and Hydra users), so another local user cannot mint
  tokens through it;
* **picks the JWT out of Hydra's output**, ignoring the environment warning lines;
* **never logs a token**, only the audience and the validity period.

## Install

```shell
# the plugin binary, built for this VM's architecture
cp ../../ext-jwt-plugin/build/linux-amd64/onboarding-agent-ext-jwt-credential-plugin bin/

vi ms-vm.env          # endpoint, workload group, HYDRA_USER, HYDRA_COMMAND
sudo ./install-ms-vm.sh
```

It installs the onboarding packages (`.deb` or `.rpm`, whichever this VM uses),
the plugin and the shim, writes both agent config files, starts the shim,
requests a token through it, prints the claims, and then starts the agent.

```shell
sudo ./install-ms-vm.sh --check-only     # request a token and show its claims, change nothing
```

Re-running is safe: files are rewritten only when their content changes.

## Settings that matter

| Variable | Notes |
| --- | --- |
| `ONBOARDING_PLANE_UID` | must equal the URL argument in the Hydra command, and the plane's own UID |
| `HYDRA_COMMAND` | run through `bash -lc`, so `module load` works; `{audience}` is substituted |
| `HYDRA_USER` | the shim runs as this user, because Hydra needs a real user's environment and credentials |
| `HYDRA_ISSUER` | `iss` of the token; the ControlPlane must trust exactly this string |
| `HYDRA_JWKS_URI` | `https://hydra-test.ms.com/.well-known/jwks`, from the issuer's discovery document; the plugin verifies the signature with it. Clear it if the VM cannot reach that URL. |

## Cluster side (not done by this script)

The ControlPlane of the cluster running the Workload Onboarding Plane must trust
the Hydra issuer, and an OnboardingPolicy must allow the subject:

```yaml
spec:
  meshExpansion:
    onboarding:
      workloads:
        authentication:
          jwt:
            issuers:
            - issuer: https://hydra-test.ms.com
              shortName: hydra
              jwksUri: <the JWKS document of the Hydra issuer>
```

```yaml
apiVersion: authorization.onboarding.tetrate.io/v1alpha1
kind: OnboardingPolicy
metadata:
  name: allow-ms-vms
  namespace: payments
spec:
  allow:
  - workloads:
    - jwt:
        issuer: https://hydra-test.ms.com
        subjects:
        - spiffe://hydra-test.ms.com/ms/user/nizam
    onboardTo:
    - workloadGroupSelector:
        matchLabels:
          app: payments
```

Two things to confirm on the first run, because they cannot be checked from here:

1. **The plane's UID must be `https://vmgateway.istio-system.rcb.use.k8s.az-dev.ms.com`**,
   since that is the `aud` Hydra puts in the token. The agent log shows the
   audience it asks for; if it differs, the token is rejected.
2. **The subject is a SPIFFE ID**, and TSB derives the WorkloadEntry name from
   the subject. Watch for a name error when the first VM onboards:
   ```shell
   kubectl -n istio-system logs deploy/onboarding-plane -f | grep -E 'authenticated a workload|denied|invalid'
   ```
   The Hydra token carries no custom attributes, so the policy can only match on
   `issuer` and `subjects`.

## What was tested

The shim and the plugin were exercised together on a laptop, with a fake `hydra`
command printing a token shaped like the real one. The plugin's own `check`
reported:

```
[ ok ] obtained a token from the issuer (EXT_JWT_TOKEN_SOURCE=access_token)
[ ok ] the 'iss' claim matches EXT_JWT_ISSUER
[ ok ] the 'aud' claim includes the Workload Onboarding Plane "https://vmgateway.istio-system…"
```

Nothing here has run against real Hydra, a real MS VM or the MS cluster.
