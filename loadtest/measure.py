"""What users wait for, action by action (E2): each main action of the app, done
the way the app does it, by one person at a time on an idle server.

    uv run python measure.py --window             # 30 times each
    uv run python measure.py --window --times 10

It makes two accounts of its own (a user and an admin, through the admin API, so
no emails), uses the saved route from prepare.py (find_or_create returns it
as it is), and deletes the accounts at the end, with their trips. It writes
nothing else. Results: .data/results/measure-<time>.md.
"""

import argparse
import json
import secrets
import statistics
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
from supabase import create_client

from loadtool import config
from loadtool.report import percentile

ACCOUNT_PREFIX = "measure-"


def make_account(client, role_id: int) -> dict:
    email = f"{ACCOUNT_PREFIX}{secrets.token_hex(4)}@eyes4u.example"
    password = secrets.token_urlsafe(18)
    user = client.auth.admin.create_user(
        {"email": email, "password": password, "email_confirm": True}
    ).user
    client.table("profiles").upsert(
        {"id": user.id, "role_id": role_id, "full_name": "measure", "is_active": True}
    ).execute()
    return {"id": user.id, "email": email, "password": password}


def delete_accounts(client) -> int:
    users = [
        u
        for u in client.auth.admin.list_users(page=1, per_page=1000)
        if (u.email or "").startswith(ACCOUNT_PREFIX)
    ]
    for user in users:
        # The profile first; its sessions and logs go with it.
        client.table("profiles").delete().eq("id", user.id).execute()
        client.auth.admin.delete_user(user.id)
    return len(users)


class App:
    """One person's app: signs in, and calls the gateway with its headers."""

    def __init__(self, env: dict, account: dict, version: str):
        self.env = env
        self.account = account
        self.version = version
        self.http = httpx.Client(base_url=env["API_GATEWAY_URL"], timeout=60)
        self.headers: dict = {}

    def sign_in(self) -> None:
        response = httpx.post(
            f"{self.env['SUPABASE_URL']}/auth/v1/token?grant_type=password",
            json={"email": self.account["email"], "password": self.account["password"]},
            headers={"apikey": self.env["SUPABASE_PUBLISHABLE_KEY"]},
            timeout=30,
        )
        response.raise_for_status()
        self.headers = {
            "Authorization": f"Bearer {response.json()['access_token']}",
            "X-App-Version": self.version,
        }

    def get(self, path: str, **kwargs):
        response = self.http.get(path, headers=self.headers, **kwargs)
        response.raise_for_status()
        return response.json()

    def post(self, path: str, **kwargs):
        response = self.http.post(path, headers=self.headers, **kwargs)
        response.raise_for_status()
        return response.json()

    def parallel(self, paths: list[str]) -> list:
        with ThreadPoolExecutor(max_workers=max(1, len(paths))) as pool:
            return list(pool.map(self.get, paths))


def timed(action) -> float:
    started = time.perf_counter()
    action()
    return (time.perf_counter() - started) * 1000


def measure(env: dict, user: App, admin: App, route: dict, tick: dict, times: int):
    stops = [
        route["start_anchor_id"],
        *route["waypoint_anchor_ids"],
        route["end_anchor_id"],
    ]
    server_ms: list[float] = []

    def app_start():
        user.sign_in()
        user.get(f"/user/profiles/{user.account['id']}")
        user.get("/user/app-version")

    def home_ready():
        user.parallel(
            [
                "/map/places",
                "/map/buildings",
                "/map/anchor-points",
                "/map/anchor-point-connections",
            ]
        )

    def find_route():
        user.post(
            "/route/routes/find_or_create",
            json={
                "start_anchor_id": route["start_anchor_id"],
                "end_anchor_id": route["end_anchor_id"],
            },
        )

    session: dict = {}
    # As the app (route_points.dart): one request where the server has by-ids.
    batch = f"/map/anchor-points/by-ids?ids={','.join(stops)}"
    has_batch = False

    def trip_start():
        """As NavigationScreen: the session, then the route's points with their
        connections: one request, or on an older server each point and each
        point's connections, each group in parallel."""
        session.update(
            user.post(
                "/navigation/sessions",
                json={
                    "user_id": user.account["id"],
                    "route_id": route["id"],
                    "building_id": route.get("building_id"),
                    "device_info": {"platform": "measure"},
                },
            )[0]
        )
        if has_batch:
            user.get(batch)
            return
        user.parallel([f"/map/anchor-points/{stop}" for stop in stops])
        user.parallel([f"/map/anchor-points/{stop}/connections" for stop in stops])

    photo = Path(tick["frame"]).read_bytes()

    def photo_correction():
        answer = user.post(
            "/positioning/correct_position",
            data={
                "session_id": session["id"],
                "latitude": str(tick["latitude"]),
                "longitude": str(tick["longitude"]),
                "accuracy": str(tick["accuracy"]),
                "gps_time": datetime.now(UTC).isoformat(),
                **(
                    {"heading": str(tick["heading"])}
                    if tick.get("heading") is not None
                    else {}
                ),
            },
            files={"photo": ("frame.jpg", photo, "image/jpeg")},
        )
        total = (answer.get("debug") or {}).get("total_ms")
        if total is not None:
            server_ms.append(total)

    def admin_open():
        admin.parallel(
            [
                "/map/places",
                "/map/buildings",
                "/map/anchor-points",
                "/map/anchor-point-photos",
                "/map/anchor-point-connections",
            ]
        )

    def admin_refresh():
        since = (datetime.now(UTC) - timedelta(seconds=30)).isoformat()
        admin.get("/map/changes", params={"since": since})

    admin.sign_in()
    user.sign_in()
    try:
        user.get(batch)
        has_batch = True
    except httpx.HTTPStatusError:
        pass
    print(f"  Trip start: {'by-ids' if has_batch else 'per point'}", flush=True)
    trip_start()  # a session for the photos
    actions = {
        "App start": app_start,
        "Home ready": home_ready,
        "Find a route": find_route,
        "Start a trip": trip_start,
        "A photo correction": photo_correction,
        "Admin opens": admin_open,
        "Admin refresh": admin_refresh,
    }
    results = {}
    for name, action in actions.items():
        action()  # once unmeasured, so a cold cache doesn't count
        samples = []
        for _ in range(times):
            samples.append(timed(action))
            # The per-point trip start is ~44 requests: the gateway's per-user
            # allowance (30/s, bursts of 60) needs a moment to refill.
            time.sleep(2 if action is trip_start else 0.3)
        results[name] = samples
        print(f"  {name}: {statistics.median(samples):.0f} ms p50", flush=True)
    return results, server_ms


def render(results: dict, server_ms: list[float], stops: int, times: int) -> str:
    def row(name, samples):
        return (
            f"| {name} | {statistics.median(samples) / 1000:.2f} s "
            f"| {percentile(samples, 0.95) / 1000:.2f} s |"
        )

    lines = [
        f"# What users wait for ({datetime.now(UTC):%Y-%m-%d %H:%M} UTC)",
        "",
        (
            f"One person at a time, each action {times} times, through the public "
            f"address. The route has {stops} points."
        ),
        "",
        "| Action | p50 | p95 |",
        "|---|---:|---:|",
        *(row(name, samples) for name, samples in results.items()),
    ]
    if server_ms:
        lines += [
            "",
            row("↳ of which the server, per photo", server_ms).replace("| ↳", "| ↳"),
        ]
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--times", type=int, default=30)
    parser.add_argument(
        "--window", action="store_true", help="nobody is testing or editing right now"
    )
    args = parser.parse_args()
    if not args.window:
        raise SystemExit("Run only in an agreed window: add --window.")
    env = config.settings()
    trips = json.loads(config.TRIPS_FILE.read_text())
    route = trips["route"]
    tick = next(t for trip in trips["trips"] for t in trip["ticks"] if t.get("frame"))
    version = json.loads(
        (config.REPO / "packages/src/packages/app_versions.json").read_text()
    )["latest"]
    client = create_client(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    try:
        user = App(env, make_account(client, config.ROLE_USER), version)
        admin = App(env, make_account(client, config.ROLE_ADMIN), version)
        results, server_ms = measure(env, user, admin, route, tick, args.times)
    finally:
        print(
            f"Deleted {delete_accounts(client)} measurement accounts, with their trips."
        )
    stops = 2 + len(route["waypoint_anchor_ids"])
    report = render(results, server_ms, stops, args.times)
    out = config.RESULTS_DIR / f"measure-{datetime.now(UTC):%Y%m%d-%H%M%S}.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(report)
    print(report)
    print(f"Saved to {out}")


if __name__ == "__main__":
    main()
