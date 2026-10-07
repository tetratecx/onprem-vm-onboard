# Keycloak setup for VM onboarding

The VM authenticates to Keycloak as an OAuth 2.0 **confidential client using the
`client_credentials` grant** - a service account, with no end user involved. The
token Keycloak mints is what TSB accepts as the VM's identity.

| File | What it does |
| --- | --- |
| `add-client.sh` | creates a client for a VM or group of VMs, with all the mappers it needs |
| `add-audience.sh` | adds the onboarding plane UID to the `aud` claim of existing clients |

Both run `kcadm.sh` inside the Keycloak pod, so they need only `kubectl` access
to the cluster running Keycloak - no admin port has to be exposed. The admin
password comes from `KC_ADMIN_PASSWORD` or is prompted for, and is passed over
stdin so it never appears in the pod's process list.

```shell
NAMESPACE=keycloak REALM=tetrate ./add-client.sh --help
```

## What a client needs

| Requirement | Why |
| --- | --- |
| Confidential client, service accounts enabled | the `client_credentials` grant; the VM has no user |
| RS256 access tokens | the plane verifies an RS256 signature against the JWKS |
| **Audience mapper carrying the plane UID** | the plane rejects a token whose `aud` lacks its UID |
| `custom_attributes.*` claim mappers | only if the `OnboardingPolicy` matches on attributes |

### Creating one

```shell
./add-client.sh \
  --client-id vm-rhel-prod \
  --secret '<a strong secret>' \
  --plane-uid https://vms.cluster.example.com \
  --region uscentral1 --datacenter datacenter1 \
  --access-level write
```

It finishes by requesting a real token and printing its claims, including the
`sub` to put in `ALLOWED_SUBJECTS` in [`../cp.env`](../cp.env). Pass `--replace`
to recreate a client that already exists.

### The audience mapper, separately

For clients that already exist, or after the plane UID changes:

```shell
./add-audience.sh 'https://vms.cluster.example.com'              # vm-write and vm-readonly
./add-audience.sh 'https://vms.cluster.example.com' vm-rhel-prod # one named client
```

Idempotent - it replaces a mapper of the same name, so re-running is safe.

> **Why this is a separate step.** The credential plugin asks Keycloak for a
> token whose audience is the plane UID, but Keycloak **ignores the `audience`
> request parameter on the `client_credentials` grant**. It does not reject the
> request - it returns a token with the realm's default audience, which the plane
> then refuses. The UID must therefore be injected by an Audience protocol
> mapper. This is the most common reason a correct-looking VM never onboards.

### By hand in the admin console

**Clients → *client* → Client scopes → *client*-dedicated → Add mapper → By
configuration → Audience**, put the plane UID in *Included Custom Audience*, and
enable *Add to access token*. For the attributes, add **Hardcoded claim** mappers
with claim names `custom_attributes.region`, `custom_attributes.datacenter` and
so on.

> If the realm is deployed from a committed realm JSON, update that file too.
> Keycloak's `--import-realm` **skips a realm that already exists**, so editing
> the JSON changes nothing on a running instance - and the live realm then drifts
> from the manifest.

## Checking what the realm issues

From the VM, which is also what the agent will see:

```shell
cd ../../vm
sudo ./get-token.sh --decode     # claims + the checks the plane applies
sudo ./get-token.sh --check      # the plugin's own report, including the signature
```

From anywhere, with just `curl`:

```shell
KC=https://keycloak.example.com/realms/tetrate

TOKEN=$(curl -s -X POST "$KC/protocol/openid-connect/token" \
  -d grant_type=client_credentials \
  -d client_id=vm-write \
  --data-urlencode "client_secret=<the secret>" | jq -r .access_token)

# the payload is base64url without padding
jwt_claims() {
  local p; p=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  while (( ${#p} % 4 )); do p+="="; done
  base64 -d <<<"$p" | jq .
}
jwt_claims "$TOKEN" | jq '{iss, aud, sub, azp, custom_attributes, exp: (.exp|todate)}'
```

A token ready to onboard has `iss` equal to the realm URL, `aud` containing the
plane UID, and a `sub` listed in `ALLOWED_SUBJECTS`.

## Operational notes

* **Token lifespan.** 900 s is comfortable - the agent renews 60 s before `exp`.
  Do not go below about five minutes.
* **Rotating a secret.** Regenerate it under **Clients → *client* →
  Credentials**, then update the VM. The plugin re-reads the secret file on every
  request, so the agent does not need restarting.
* **One client per policy group.** `custom_attributes` are hardcoded per client,
  so every VM sharing a client reports the same attribute values. VMs that need
  different values need different clients.
* **`access_level` and other top-level claims** cannot be matched by an
  `OnboardingPolicy`, which only reads `custom_attributes`. `add-client.sh`
  therefore also writes it as `custom_attributes.access_level`.

## Using an identity provider other than Keycloak

Nothing in TSB is Keycloak-specific. Any OIDC provider works if it can:

1. issue **RS256-signed JWTs** from a reachable JWKS endpoint;
2. serve a **token endpoint** accepting `client_credentials` (or another grant the
   plugin supports: `password`, `refresh_token`, `urn:ietf:params:oauth:grant-type:token-exchange`);
3. include the **onboarding plane UID in `aud`**;
4. put any attributes a policy matches into **one JSON object of string values**,
   pointed at by `tokenFields.attributes.jsonPath`.

Then change `KEYCLOAK_REALM_URL` in [`../cp.env`](../cp.env) and
[`../../vm/vm.env`](../../vm/vm.env) to the new issuer, and adjust
`EXT_JWT_GRANT_TYPE` in
[`../../vm/templates/agent.config.yaml.tmpl`](../../vm/templates/agent.config.yaml.tmpl)
if the grant differs. The token and JWKS paths are derived from the realm URL in
the Keycloak layout; for a different provider, set `EXT_JWT_TOKEN_ENDPOINT` and
`EXT_JWT_JWKS_URI` to its real endpoints.
