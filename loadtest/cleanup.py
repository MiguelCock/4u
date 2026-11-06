"""Removes everything a run made, and checks real data came out unchanged.

    uv run python cleanup.py

Safe to run twice. Exits with an error if anything of ours is left.
"""

import json
import sys

import httpx
from supabase import create_client

from loadtool import config
from provision import real_counts


def list_loadtest_users(client) -> list:
    found, page = [], 1
    while True:
        users = client.auth.admin.list_users(page=page, per_page=200)
        found += [u for u in users if config.is_loadtest_email(u.email)]
        if len(users) < 200:
            return found
        page += 1


def sign_in(env: dict, account: dict) -> str | None:
    response = httpx.post(
        f"{env['SUPABASE_URL']}/auth/v1/token?grant_type=password",
        json={"email": account["email"], "password": account["password"]},
        headers={"apikey": env["SUPABASE_PUBLISHABLE_KEY"]},
        timeout=30,
    )
    return response.json().get("access_token") if response.is_success else None


def remove_sandbox(client, env: dict, state: dict) -> None:
    """Through the API, as the app does, so Qdrant entries and photo files go
    with it. Only ever the place with the sandbox's own code."""
    places = (
        client.table("places")
        .select("id")
        .eq("code", config.SANDBOX_PLACE_CODE)
        .execute()
        .data
    )
    if not places:
        print("Sandbox: already gone")
        return
    token = next(
        (t for a in state.get("admin_accounts", []) if (t := sign_in(env, a))), None
    )
    if token is None:
        sys.exit("No test admin can sign in, so the sandbox can't be removed safely.")
    headers = {"Authorization": f"Bearer {token}"}
    api = env["API_GATEWAY_URL"]
    for place in places:
        buildings = (
            client.table("buildings")
            .select("id")
            .eq("place_id", place["id"])
            .execute()
            .data
        )
        for building in buildings:
            response = httpx.delete(
                f"{api}/ai-training/index_building/{building['id']}",
                headers=headers,
                timeout=120,
            )
            print(f"Photo search entries of the sandbox: {response.status_code}")
            response.raise_for_status()
        response = httpx.delete(
            f"{api}/map/places/{place['id']}", headers=headers, timeout=120
        )
        print(f"Sandbox: {response.status_code}")
        response.raise_for_status()
    for run_uploads in config.RESULTS_DIR.rglob("uploads.txt"):
        for url in run_uploads.read_text().split():
            # Refused by the server if a photo still uses it; those already went.
            httpx.delete(
                f"{api}/map/anchor-points/upload-image",
                params={"url": url},
                headers=headers,
                timeout=30,
            )


def main() -> None:
    env = config.settings()
    client = create_client(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    state = (
        json.loads(config.ACCOUNTS_FILE.read_text())
        if config.ACCOUNTS_FILE.exists()
        else {}
    )
    remove_sandbox(client, env, state)

    users = list_loadtest_users(client)
    for user in users:
        # Sessions, logs and feedback go with the profile.
        client.table("profiles").delete().eq("id", user.id).execute()
        client.auth.admin.delete_user(user.id)
    print(f"Accounts removed: {len(users)}")

    problems = []
    if list_loadtest_users(client):
        problems.append("loadtest accounts are still there")
    left = (
        client.table("places")
        .select("id")
        .eq("code", config.SANDBOX_PLACE_CODE)
        .execute()
        .data
    )
    if left:
        problems.append("the sandbox is still there")
    if problems:
        sys.exit("NOT clean: " + "; ".join(problems))

    before = state.get("before")
    if before:
        after = real_counts(client)
        changed = {t: (before[t], after[t]) for t in before if before[t] != after[t]}
        if changed:
            print(
                "Real data counts changed (before, after). Expected only if someone "
                f"edited the map during the run; otherwise investigate: {changed}"
            )
        else:
            print(f"Real data counts match: {after}")
    config.ACCOUNTS_FILE.unlink(missing_ok=True)
    print("Clean.")


if __name__ == "__main__":
    main()
