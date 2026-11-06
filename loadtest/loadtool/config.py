"""Where things are, and what the sandbox looks like. Nothing here talks to a
server, so the locustfile can import it before gevent patches anything."""

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT.parent

# Everything local and private: photos can show people, and accounts.json holds
# passwords. Never committed (see .gitignore).
DATA_DIR = ROOT / ".data"
TRIPS_FILE = DATA_DIR / "trips.json"
ACCOUNTS_FILE = DATA_DIR / "accounts.json"
RESULTS_DIR = DATA_DIR / "results"

SERVER_HOST = "ec2-user@i-08ee7be989aa9721f"
INSTANCE_ID = "i-08ee7be989aa9721f"

NAV_ACCOUNTS = 20
ADMIN_ACCOUNTS = 10
ROLE_USER = 1
ROLE_ADMIN = 2

# An inactive university far from any campus (the plains of eastern Colombia):
# users are never offered it, and photo search only looks within 60 m of the
# user, so its photos can't match a real search.
SANDBOX_PLACE_CODE = "LOADTEST"
SANDBOX_NAME = "Prueba de carga"
SANDBOX_LAT = 4.0
SANDBOX_LNG = -71.5

# EAFIT test walks with their camera frames stored, to replay.
TRIP_SESSION_PREFIXES = ("73916c0d", "f0fb7820")
CAMPUS = "EAFIT"


def account_email(role: str, number: int) -> str:
    return f"loadtest-{role}-{number:02d}@eyes4u.example"


def is_loadtest_email(email: str | None) -> bool:
    return bool(email) and email.startswith("loadtest-")


def _read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip("\"'")
    return values


def settings() -> dict[str, str]:
    """The service key only ever comes from packages/.env, and the gateway and
    publishable key from the app's .env, so a run hits what the app hits."""
    server = _read_env_file(REPO / "packages" / ".env")
    app = _read_env_file(REPO / "application" / ".env")
    merged = {
        "SUPABASE_URL": server.get("SUPABASE_URL", ""),
        "SUPABASE_SERVICE_ROLE_KEY": server.get("SUPABASE_SERVICE_ROLE_KEY", ""),
        "SUPABASE_PUBLISHABLE_KEY": app.get("SUPABASE_PUBLISHABLE_KEY", ""),
        "API_GATEWAY_URL": app.get("API_GATEWAY_URL", "").rstrip("/"),
    }
    return {key: os.environ.get(key, value) for key, value in merged.items()}
