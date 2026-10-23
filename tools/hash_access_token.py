#!/usr/bin/env python3
"""Print the HMAC fingerprint used by the local access_tokens table."""

import hashlib
import hmac
import os
import sys


pepper = os.environ.get("AUTH_TOKEN_PEPPER", "").encode("utf-8")
if len(pepper) < 32:
    raise SystemExit("AUTH_TOKEN_PEPPER must contain at least 32 bytes")

token = sys.stdin.buffer.read().rstrip(b"\r\n")
if not token:
    raise SystemExit("read a non-empty access token from stdin")

print(hmac.new(pepper, token, hashlib.sha1).hexdigest())
