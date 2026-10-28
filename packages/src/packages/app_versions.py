"""Which versions of the app the backend still serves.

Two versions are supported at a time: the newest release and the one
before it, which is deprecated (it works, and the app tells its user to
update). Anything older gets 426 Upgrade Required. app_versions.json is the
one source of truth; scripts/bump_version.py rewrites it in every release
PR (the new version becomes `latest`, the old `latest` becomes
`min_supported`), and every service reads it, since all of them ship this
package.
"""

import json
import os
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

VERSION_HEADER = "X-App-Version"

# Releases up to this one never sent VERSION_HEADER. A request with a bearer
# token but no header comes from one of them, so it's judged as this.
LEGACY_VERSION = "0.5.1"

_POLICY_FILE = Path(__file__).with_name("app_versions.json")


def load_policy(path: Path = _POLICY_FILE) -> dict:
    return json.loads(path.read_text())


def parse_version(value: str) -> tuple[int, ...]:
    """ "0.5.2" or "0.5.2+502" -> (0, 5, 2). Anything unparsable is (0,):
    older than every real release."""
    core = value.strip().split("+", 1)[0].split("-", 1)[0]
    try:
        return tuple(int(part) for part in core.split("."))
    except ValueError:
        return (0,)


def caller_version(headers) -> str | None:
    """The app version a request comes from, or None for an internal call
    (no app header and no bearer token, e.g. backend-positioning calling
    backend-ai-training)."""
    version = headers.get(VERSION_HEADER)
    if version:
        return version
    if headers.get("authorization"):
        return LEGACY_VERSION
    return None


def is_supported(version: str, policy: dict) -> bool:
    return parse_version(version) >= parse_version(policy["min_supported"])


def install_app_version_guard(app: FastAPI, policy: dict | None = None) -> None:
    """Refuses requests from app versions older than `min_supported` with
    426 and the policy, so the app can show its "update required" screen.
    Health checks (`GET /`) and internal calls always pass.

    APP_VERSION_GUARD=off skips it: the services' own test suites set that,
    so their bearer-token requests don't start failing as "legacy app" the
    day `min_supported` moves past LEGACY_VERSION."""
    if policy is None and os.environ.get("APP_VERSION_GUARD") == "off":
        return
    policy = policy or load_policy()

    @app.middleware("http")
    async def _guard(request: Request, call_next):
        version = caller_version(request.headers)
        if (
            version is not None
            and request.url.path != "/"
            and not is_supported(version, policy)
        ):
            return JSONResponse(
                status_code=426,
                content={
                    "detail": "This version of the app is no longer supported. "
                    "Please update.",
                    **policy,
                },
            )
        return await call_next(request)
