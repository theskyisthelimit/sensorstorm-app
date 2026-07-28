#!/usr/bin/env python3
"""Minimal App Store Connect API client (JWT + requests via urllib).

Identical to the aarestation-app tool of the same name — same key location, same
env vars — so both projects are driven the same way from one machine.

Usage:
  export ASC_KEY_ID=...
  export ASC_ISSUER_ID=...
  asc.py GET  /v1/apps
  asc.py GET  '/v1/builds?filter[app]=APP_ID&limit=5'
  asc.py POST /v1/profiles body.json
"""
import json
import os
import sys
import time
import ssl
import urllib.request
import urllib.error

import certifi
import jwt  # pyjwt

_SSL_CTX = ssl.create_default_context(cafile=certifi.where())

KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
KEY_PATH = os.environ.get(
    "ASC_KEY_PATH",
    os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"),
)
BASE = "https://api.appstoreconnect.apple.com"


def token() -> str:
    with open(KEY_PATH) as f:
        private_key = f.read()
    now = int(time.time())
    payload = {
        "iss": ISSUER_ID,
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, private_key, algorithm="ES256",
                      headers={"kid": KEY_ID, "typ": "JWT"})


def request(method: str, path: str, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=_SSL_CTX) as resp:
            raw = resp.read().decode()
            return resp.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    method = sys.argv[1].upper()
    path = sys.argv[2]
    body = None
    if len(sys.argv) > 3:
        with open(sys.argv[3]) as f:
            body = json.load(f)
    status, raw = request(method, path, body)
    print(f"HTTP {status}", file=sys.stderr)
    print(raw)
    if status >= 400:
        sys.exit(1)


if __name__ == "__main__":
    main()
