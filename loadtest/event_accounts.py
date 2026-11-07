"""Attendee accounts for an event (A4), made with the admin API, which sends no
email: sign-ups once hit Supabase's email limit.

    uv run python event_accounts.py --create 12
    uv run python event_accounts.py --delete --yes     # also deletes their trips

The list, with passwords, goes to .data/event-accounts.csv, readable only by you,
for printing. It's never shown in the terminal. Run event_report.py before
deleting: an account's trips go with it.
"""

import argparse
import csv
import secrets

from supabase import create_client

from loadtool import config

LIST = config.DATA_DIR / "event-accounts.csv"
PREFIX = "evento-"
DOMAIN = "eyes4u.example"
# Easy to read out and type on a phone. Three of 40 words and 4 digits: about
# 576 million passwords, for accounts that should only live for the event.
WORDS = [
    "faro",
    "luna",
    "sol",
    "rio",
    "mar",
    "nube",
    "hoja",
    "roca",
    "pino",
    "lago",
    "cielo",
    "trigo",
    "miel",
    "brisa",
    "coral",
    "perla",
    "cobre",
    "jade",
    "lima",
    "rosa",
    "arena",
    "bosque",
    "campo",
    "cerro",
    "duna",
    "flor",
    "fuego",
    "hielo",
    "isla",
    "jardin",
    "lluvia",
    "monte",
    "nido",
    "olivo",
    "palma",
    "piedra",
    "puente",
    "selva",
    "tierra",
    "valle",
]


def password() -> str:
    words = "-".join(secrets.choice(WORDS) for _ in range(3))
    return f"{words}-{secrets.randbelow(9000) + 1000}"


def is_event_email(email: str | None) -> bool:
    return bool(email) and email.startswith(PREFIX) and email.endswith("@" + DOMAIN)


def event_users(client) -> list:
    users, page = [], 1
    while True:
        batch = client.auth.admin.list_users(page=page, per_page=200)
        users += [u for u in batch if is_event_email(u.email)]
        if len(batch) < 200:
            return users
        page += 1


def create(client, count: int) -> None:
    if LIST.exists():
        raise SystemExit(f"{LIST} exists: delete the old accounts first (--delete).")
    if event_users(client):
        raise SystemExit("Event accounts already exist: --delete them first.")
    rows = []
    for number in range(1, count + 1):
        email = f"{PREFIX}{number:02d}@{DOMAIN}"
        secret = password()
        user = client.auth.admin.create_user(
            {"email": email, "password": secret, "email_confirm": True}
        ).user
        client.table("profiles").upsert(
            {
                "id": user.id,
                "role_id": config.ROLE_USER,
                "full_name": f"Evento {number:02d}",
                "is_active": True,
            }
        ).execute()
        rows.append({"email": email, "password": secret})
    LIST.parent.mkdir(parents=True, exist_ok=True)
    LIST.touch(mode=0o600)
    with LIST.open("w", newline="") as file:
        writer = csv.DictWriter(file, ["email", "password"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"Created {count} accounts. The list is in {LIST}.")


def delete(client) -> None:
    users = event_users(client)
    for user in users:
        # The profile first: Supabase refuses to delete a user that one points to.
        # Its trips go with it (navigation_sessions cascade from profiles).
        client.table("profiles").delete().eq("id", user.id).execute()
        client.auth.admin.delete_user(user.id)
    LIST.unlink(missing_ok=True)
    print(f"Deleted {len(users)} accounts, with their trips.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--create", type=int, metavar="COUNT")
    action.add_argument("--delete", action="store_true")
    parser.add_argument("--yes", action="store_true", help="confirms --delete")
    args = parser.parse_args()
    env = config.settings()
    client = create_client(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    if args.create:
        create(client, args.create)
    elif not args.yes:
        raise SystemExit("--delete also deletes their trips. Add --yes to go ahead.")
    else:
        delete(client)


if __name__ == "__main__":
    main()
