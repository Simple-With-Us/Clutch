#!/usr/bin/env python3
"""Fetch allowlisted Clutch settings with a scoped service token into a private env file."""

import json
import ipaddress
import os
import shlex
import stat
import sys
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise HTTPError(req.full_url, code, "redirects are disabled for Infisical", headers, fp)


def validated_site(site: str) -> str:
    try:
        parsed = urlsplit(site)
        hostname = parsed.hostname
        # Accessing .port also validates malformed ports and authorities.
        _ = parsed.port
    except ValueError as error:
        raise ValueError("invalid Infisical URL") from error
    if not hostname or parsed.username is not None or parsed.password is not None:
        raise ValueError("invalid Infisical URL authority")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError("Infisical URL must be a base origin")
    if parsed.scheme == "https":
        return f"https://{parsed.netloc}"
    if parsed.scheme == "http":
        try:
            if not ipaddress.ip_address(hostname).is_loopback:
                raise ValueError("plain HTTP is allowed only for a loopback test server")
        except ValueError as error:
            raise ValueError("plain HTTP is allowed only for a literal loopback test server") from error
        return f"http://{parsed.netloc}"
    raise ValueError("Infisical URL must use HTTPS")


def service_token_matches(data: object, project: str, environment: str, secret_path: str, permission: str) -> bool:
    if not isinstance(data, dict):
        return False
    if "serviceTokenData" in data and not isinstance(data["serviceTokenData"], dict):
        return False
    metadata = data["serviceTokenData"] if "serviceTokenData" in data else data
    if not isinstance(metadata, dict):
        return False
    if metadata.get("projectId") != project:
        return False
    if "workspace" in metadata and metadata.get("workspace") != project:
        return False
    expires_at = metadata.get("expiresAt")
    if expires_at is not None:
        if not isinstance(expires_at, str):
            return False
        try:
            expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        except ValueError:
            return False
        if expiry.tzinfo is None or expiry <= datetime.now(timezone.utc):
            return False
    permissions = metadata.get("permissions")
    scopes = metadata.get("scopes")
    if permissions != [permission] or not isinstance(scopes, list) or len(scopes) != 1:
        return False
    scope = scopes[0]
    return (
        isinstance(scope, dict)
        and set(scope) == {"secretPath", "environment"}
        and scope.get("secretPath") == secret_path
        and scope.get("environment") == environment
    )


def verify_service_token(site: str, token: str, project: str, environment: str, secret_path: str, permission: str) -> bool:
    request = Request(
        f"{site}/api/v2/service-token",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with build_opener(NoRedirectHandler).open(request, timeout=20) as response:
            metadata = json.load(response)
    except Exception:
        return False
    return service_token_matches(metadata, project, environment, secret_path, permission)


def main() -> int:
    token = os.environ.get("INFISICAL_TOKEN", "").strip()
    project = os.environ.get("INFISICAL_PROJECT_ID", "").strip() or os.environ.get("CLUTCH_INFISICAL_PROJECT_ID", "").strip()
    output = os.environ.get("CLUTCH_INFISICAL_OUTPUT_FILE", "")
    site = os.environ.get("CLUTCH_INFISICAL_URL") or os.environ.get("INFISICAL_SITE_URL") or "https://app.infisical.com"
    keys = os.environ.get("CLUTCH_MANAGED_KEYS", "").split()
    if not token:
        print("clutch-infisical-env: no read service token — keeping process environment", file=sys.stderr)
        return 0
    if not token.startswith("st.") or not 20 <= len(token) <= 2048 or any(ch.isspace() for ch in token):
        print("clutch-infisical-env: read service token is invalid — keeping process environment", file=sys.stderr)
        return 0
    if not project or not output:
        print("clutch-infisical-env: project ID or private output file is missing — keeping process environment", file=sys.stderr)
        return 0
    try:
        site = validated_site(site)
    except ValueError:
        print("clutch-infisical-env: Infisical URL is invalid or unsafe — keeping process environment", file=sys.stderr)
        return 0
    try:
        if stat.S_IMODE(os.stat(output).st_mode) & 0o077:
            print("clutch-infisical-env: output file permissions are too broad — keeping process environment", file=sys.stderr)
            return 0
    except OSError:
        print("clutch-infisical-env: private output file is unavailable — keeping process environment", file=sys.stderr)
        return 0

    if not verify_service_token(site, token, project, "prod", "/", "read"):
        print("clutch-infisical-env: service token scope verification failed — keeping process environment", file=sys.stderr)
        return 0

    query = urlencode({
        "workspaceId": project,
        "environment": "prod",
        "secretPath": "/",
        "recursive": "false",
        "include_imports": "false",
        "expandSecretReferences": "false",
    })
    request = Request(
        f"{site}/api/v3/secrets/raw?{query}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with build_opener(NoRedirectHandler).open(request, timeout=20) as response:
            data = json.load(response)
    except HTTPError as error:
        print(f"clutch-infisical-env: secrets fetch failed (HTTP {error.code}) — keeping process environment", file=sys.stderr)
        return 0
    except (URLError, TimeoutError, OSError, ValueError):
        print("clutch-infisical-env: secrets fetch failed — keeping process environment", file=sys.stderr)
        return 0

    if not isinstance(data, dict) or not isinstance(data.get("secrets"), list):
        print("clutch-infisical-env: secrets response was invalid — keeping process environment", file=sys.stderr)
        return 0
    values = {
        item.get("secretKey"): item.get("secretValue", "")
        for item in data["secrets"]
        if isinstance(item, dict) and isinstance(item.get("secretKey"), str)
    }
    filled = []
    exports = []
    for key in keys:
        if os.environ.get(key):
            continue
        value = values.get(key)
        if isinstance(value, str) and value:
            exports.append(f"export {shlex.quote(key)}={shlex.quote(value)}\n")
            filled.append(key)
    try:
        with open(output, "w", encoding="utf-8") as env_file:
            env_file.writelines(exports)
    except OSError:
        print("clutch-infisical-env: could not write the private output file — keeping process environment", file=sys.stderr)
        return 0
    if filled:
        print("clutch-infisical-env: backfilled from Infisical: " + " ".join(filled), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
