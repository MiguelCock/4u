import json

from fastapi import FastAPI
from fastapi.testclient import TestClient

from packages.app_versions import (
    LEGACY_VERSION,
    install_app_version_guard,
    is_supported,
    load_policy,
    parse_version,
)

POLICY = {
    "latest": "0.5.3",
    "min_supported": "0.5.2",
    "download_url": "https://example.com/latest",
}


def _client(policy=POLICY) -> TestClient:
    app = FastAPI()
    install_app_version_guard(app, policy)

    @app.get("/")
    def root():
        return {"ok": True}

    @app.get("/things")
    def things():
        return []

    return TestClient(app)


def test_parse_version():
    assert parse_version("0.5.2") == (0, 5, 2)
    assert parse_version("0.5.2+502") == (0, 5, 2)
    assert parse_version("0.10.0") > parse_version("0.9.9")
    assert parse_version("garbage") == (0,)


def test_supported_window():
    assert is_supported("0.5.3", POLICY)
    assert is_supported("0.5.2", POLICY)  # deprecated, still served
    assert not is_supported("0.5.1", POLICY)


def test_current_and_deprecated_versions_pass():
    client = _client()
    for version in ("0.5.3", "0.5.2"):
        assert (
            client.get("/things", headers={"X-App-Version": version}).status_code == 200
        )


def test_older_versions_get_426_with_the_policy():
    response = _client().get("/things", headers={"X-App-Version": "0.5.1"})
    assert response.status_code == 426
    assert response.json()["download_url"] == POLICY["download_url"]
    assert response.json()["min_supported"] == "0.5.2"


def test_app_without_the_header_counts_as_the_legacy_version():
    headers = {"Authorization": "Bearer token"}
    assert _client().get("/things", headers=headers).status_code == 426
    lenient = {**POLICY, "min_supported": LEGACY_VERSION}
    assert _client(lenient).get("/things", headers=headers).status_code == 200


def test_internal_calls_and_health_checks_always_pass():
    client = _client()
    assert client.get("/things").status_code == 200
    assert client.get("/", headers={"X-App-Version": "0.1.0"}).status_code == 200


def test_shipped_policy_is_valid():
    policy = load_policy()
    assert set(policy) >= {"latest", "min_supported", "download_url"}
    assert parse_version(policy["min_supported"]) <= parse_version(policy["latest"])
    json.dumps(policy)


def test_policy_latest_matches_the_app_version():
    # scripts/bump_version.py updates both; a release PR that edited only
    # one would ship an app the backend calls outdated (or vice versa).
    import re
    from pathlib import Path

    pubspec = Path(__file__).parents[2] / "application" / "pubspec.yaml"
    version = re.search(r"^version:\s*(\S+)", pubspec.read_text(), re.MULTILINE).group(
        1
    )
    assert parse_version(version) == parse_version(load_policy()["latest"])
