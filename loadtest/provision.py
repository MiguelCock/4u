"""Creates the test accounts and the sandbox. Writes to production, so run it
only in the agreed window; run.py calls it. cleanup.py removes it all.

Accounts are created with the admin API, which sends no email.
"""

import json
import secrets

from supabase import create_client

from loadtool import config

COUNTED_TABLES = (
    "places",
    "buildings",
    "anchor_points",
    "anchor_point_connections",
    "anchor_point_photos",
    "routes",
)


def real_counts(client) -> dict[str, int]:
    return {
        table: client.table(table).select("id", count="exact").limit(1).execute().count
        for table in COUNTED_TABLES
    }


def create_account(client, role: str, number: int, role_id: int) -> dict:
    email = config.account_email(role, number)
    password = secrets.token_urlsafe(24)
    user = client.auth.admin.create_user(
        {
            "email": email,
            "password": password,
            "email_confirm": True,
            "user_metadata": {"full_name": f"loadtest {role} {number:02d}"},
        }
    ).user
    client.table("profiles").upsert(
        {
            "id": user.id,
            "role_id": role_id,
            "full_name": f"loadtest {role} {number:02d}",
            "is_active": True,
        }
    ).execute()
    return {"id": user.id, "email": email, "password": password}


def main() -> None:
    env = config.settings()
    client = create_client(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    if config.ACCOUNTS_FILE.exists():
        raise SystemExit(
            f"{config.ACCOUNTS_FILE} exists: run cleanup.py first, so nothing is left."
        )
    # Before anything is created, for cleanup.py to compare against.
    before = real_counts(client)
    state: dict = {"before": before, "nav_accounts": [], "admin_accounts": []}
    config.DATA_DIR.mkdir(exist_ok=True)
    try:
        for number in range(config.NAV_ACCOUNTS):
            state["nav_accounts"].append(
                create_account(client, "nav", number, config.ROLE_USER)
            )
        for number in range(config.ADMIN_ACCOUNTS):
            state["admin_accounts"].append(
                create_account(client, "admin", number, config.ROLE_ADMIN)
            )
        place = (
            client.table("places")
            .insert(
                {
                    "code": config.SANDBOX_PLACE_CODE,
                    "name": config.SANDBOX_NAME,
                    "latitude": config.SANDBOX_LAT,
                    "longitude": config.SANDBOX_LNG,
                    "is_active": False,
                }
            )
            .execute()
            .data[0]
        )
        building = (
            client.table("buildings")
            .insert(
                {
                    "place_id": place["id"],
                    "code": config.SANDBOX_PLACE_CODE,
                    "name": config.SANDBOX_NAME,
                    "latitude": config.SANDBOX_LAT,
                    "longitude": config.SANDBOX_LNG,
                    "floors": 1,
                    "is_active": False,
                }
            )
            .execute()
            .data[0]
        )
        state["sandbox"] = {
            "place_id": place["id"],
            "building_id": building["id"],
            "latitude": config.SANDBOX_LAT,
            "longitude": config.SANDBOX_LNG,
        }
    finally:
        # Written even on a failure, so cleanup.py can remove what was made.
        config.ACCOUNTS_FILE.write_text(json.dumps(state))
        config.ACCOUNTS_FILE.chmod(0o600)
    print(
        f"Created {len(state['nav_accounts'])} user and "
        f"{len(state['admin_accounts'])} admin accounts, and the sandbox."
    )


if __name__ == "__main__":
    main()
