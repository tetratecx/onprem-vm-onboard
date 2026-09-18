#!/usr/bin/env python3
"""A minimal OAuth 2.0 token endpoint in front of the Hydra CLI.

The External JWT Credential Plugin speaks OAuth 2.0: it POSTs to a token
endpoint and expects a JSON token response. Hydra hands out its token through a
command line instead:

    hydra -e dev service token https://vmgateway.istio-system.../

This shim bridges the two. It listens on 127.0.0.1, runs the Hydra command for
the audience the plugin asks for, and answers with:

    {"access_token": "<token>", "token_type": "Bearer", "expires_in": <seconds>}

so nothing in the plugin or the Onboarding Agent has to change.

Configuration comes from the environment (see hydra-token-shim.service):

    SHIM_LISTEN_ADDRESS   default 127.0.0.1
    SHIM_LISTEN_PORT      default 9099
    SHIM_SECRET_FILE      if set, the request must carry this client_secret
    HYDRA_COMMAND         shell command, {audience} is substituted
    HYDRA_TIMEOUT         seconds to wait for the command, default 60
    SHIM_CACHE_SKEW       seconds before 'exp' a cached token is dropped, default 120
"""

import base64
import json
import os
import shlex
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

LISTEN_ADDRESS = os.environ.get("SHIM_LISTEN_ADDRESS", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("SHIM_LISTEN_PORT", "9099"))
SECRET_FILE = os.environ.get("SHIM_SECRET_FILE", "")
HYDRA_COMMAND = os.environ.get(
    "HYDRA_COMMAND",
    "module load cloud/hydra/dev >/dev/null 2>&1; hydra -e dev service token {audience}",
)
HYDRA_TIMEOUT = int(os.environ.get("HYDRA_TIMEOUT", "60"))
CACHE_SKEW = int(os.environ.get("SHIM_CACHE_SKEW", "120"))

_cache = {}  # audience -> (token, expires_at)
_lock = threading.Lock()


def log(message):
    """Log to stderr; journald picks it up. Never log a token."""
    print(f"hydra-token-shim: {message}", file=sys.stderr, flush=True)


def token_expiry(token):
    """The 'exp' claim of a JWT, or None if it cannot be read."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        return int(claims["exp"])
    except Exception:
        return None


def run_hydra(audience):
    """Run the Hydra command for one audience and return the token it prints."""
    command = HYDRA_COMMAND.replace("{audience}", shlex.quote(audience))
    result = subprocess.run(
        ["bash", "-lc", command],
        capture_output=True,
        text=True,
        timeout=HYDRA_TIMEOUT,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip().splitlines()
        raise RuntimeError(
            f"the hydra command exited with {result.returncode}: "
            f"{stderr[-1] if stderr else 'no output on stderr'}"
        )

    # Hydra prints warnings alongside the token: take the last line that looks
    # like a JWT (three dot-separated segments)
    token = ""
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.count(".") == 2 and " " not in line and len(line) > 40:
            token = line
    if not token:
        raise RuntimeError("the hydra command did not print a JWT token")
    return token


def get_token(audience):
    """A cached token for this audience, or a fresh one."""
    now = time.time()
    with _lock:
        cached = _cache.get(audience)
        if cached and cached[1] - CACHE_SKEW > now:
            return cached[0], int(cached[1] - now)

    token = run_hydra(audience)
    expires_at = token_expiry(token)
    if expires_at is None:
        # no readable 'exp': serve it, but do not cache it
        log(f"could not read 'exp' from the token for audience {audience!r}")
        return token, 300

    with _lock:
        _cache[audience] = (token, expires_at)
    log(f"obtained a token for audience {audience!r}, valid for {int(expires_at - now)}s")
    return token, int(expires_at - now)


def expected_secret():
    if not SECRET_FILE:
        return None
    try:
        with open(SECRET_FILE) as f:
            return f.read().strip()
    except OSError as e:
        log(f"cannot read {SECRET_FILE}: {e}")
        return None


class Handler(BaseHTTPRequestHandler):
    server_version = "hydra-token-shim"

    def log_message(self, fmt, *args):  # quieter than the default access log
        pass

    def _json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _error(self, status, code, description):
        log(f"{code}: {description}")
        self._json(status, {"error": code, "error_description": description})

    def do_GET(self):
        if self.path.rstrip("/") in ("/healthz", "/health"):
            self._json(200, {"status": "ok"})
        else:
            self._error(404, "invalid_request", f"no such path: {self.path}")

    def do_POST(self):
        if self.path.rstrip("/") not in ("/token", ""):
            self._error(404, "invalid_request", f"no such path: {self.path}")
            return

        length = int(self.headers.get("Content-Length") or 0)
        form = parse_qs(self.rfile.read(length).decode(), keep_blank_values=True)
        get = lambda name: (form.get(name) or [""])[0]  # noqa: E731

        secret = expected_secret()
        if secret is not None and get("client_secret") != secret:
            # keeps any other local user from minting tokens through the shim
            self._error(401, "invalid_client", "wrong or missing client_secret")
            return

        grant_type = get("grant_type")
        if grant_type != "client_credentials":
            self._error(400, "unsupported_grant_type", f"unsupported grant_type: {grant_type!r}")
            return

        # the plugin sends the UID of the Workload Onboarding Plane here
        audience = get("audience") or get("resource")
        if not audience:
            self._error(400, "invalid_request", "no 'audience' in the request")
            return

        try:
            token, expires_in = get_token(audience)
        except subprocess.TimeoutExpired:
            self._error(504, "temporarily_unavailable", f"the hydra command timed out after {HYDRA_TIMEOUT}s")
            return
        except Exception as e:  # noqa: BLE001 - reported to the plugin as-is
            self._error(502, "temporarily_unavailable", str(e))
            return

        self._json(200, {
            "access_token": token,
            "token_type": "Bearer",
            "expires_in": expires_in,
        })


def main():
    server = ThreadingHTTPServer((LISTEN_ADDRESS, LISTEN_PORT), Handler)
    log(f"listening on {LISTEN_ADDRESS}:{LISTEN_PORT}")
    log(f"hydra command: {HYDRA_COMMAND}")
    log("client_secret required" if SECRET_FILE else "no client_secret required")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
