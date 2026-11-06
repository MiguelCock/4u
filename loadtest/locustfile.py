"""Simulated people, copying what the app sends. See README.md.

Every write goes through a WriteGuard, so a mistake here can't touch real data.
"""

import itertools
import json
import os
import random
import time
from datetime import UTC, datetime
from pathlib import Path

import gevent
from locust import HttpUser, between, constant, events, task

from loadtool.guards import WriteGuard
from loadtool.report import latest_memory_mb, stop_reason
from loadtool.trips import ping_pong_index, start_offset

PHOTO_ENDPOINT = "/positioning/correct_position"
# Without one, a frozen server holds every simulated user, and the run, forever.
REQUEST_TIMEOUT_SECONDS = 60
TICK_TYPE = "TICK"

# What the phone does between photos, on top of the server's answer. The app
# waits 1 s after finishing a tick; taking the photo is the rest. Calibrated by
# the baseline run against the gaps real trips logged (about 3 s).
AFTER_TICK_SECONDS = 1.0
CAPTURE_SECONDS = float(os.environ.get("LOADTEST_CAPTURE_SECONDS", "0.5"))

# Admins' points in the sandbox: rows of 10 m steps, all within the 300 m the
# backend allows from the building.
POINT_STEP_DEGREES = 0.00009
ROW_STEP_DEGREES = 0.00015
POINTS_PER_ROW = 20
MAX_POINTS_PER_ADMIN = 40

STATE = json.loads(Path(os.environ["LOADTEST_STATE"]).read_text())
RESULTS = Path(os.environ["LOADTEST_RESULTS"])
RESULTS.mkdir(parents=True, exist_ok=True)
APP_VERSION = STATE["app_version"]
_nav_numbers = itertools.count()
_admin_numbers = itertools.count()


def _read_frames() -> list[dict]:
    ticks = []
    for trip in STATE["trips"]:
        for tick in trip["ticks"]:
            ticks.append({**tick, "photo": Path(tick["frame"]).read_bytes()})
    return ticks


TICKS = _read_frames()


class Person(HttpUser):
    abstract = True
    host = STATE["api_url"]

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        request = self.client.request

        def with_timeout(method, url, **options):
            options.setdefault("timeout", REQUEST_TIMEOUT_SECONDS)
            return request(method, url, **options)

        self.client.request = with_timeout

    def sign_in(self, account: dict) -> None:
        response = self.client.post(
            f"{STATE['supabase_url']}/auth/v1/token?grant_type=password",
            json={"email": account["email"], "password": account["password"]},
            headers={"apikey": STATE["publishable_key"]},
            name="sign in",
        )
        body = response.json() if response.ok else {}
        self.token = body.get("access_token")
        self.user_id = account["id"]
        self.headers = {
            "Authorization": f"Bearer {self.token}",
            "X-App-Version": APP_VERSION,
        }

    def get(self, path: str, name: str | None = None):
        return self.client.get(path, headers=self.headers, name=name or path)

    def write(self, method: str, path: str, body: dict, name: str | None = None):
        self.guard.check(method, path, body)
        return self.client.request(
            method, path, json=body, headers=self.headers, name=name or path
        )

    def read_lists(self) -> None:
        for path in ("/map/places", "/map/buildings", "/map/anchor-points"):
            self.get(path)


class NavigatingUser(Person):
    """A person on a trip: home, route, then a photo and a log per tick."""

    fixed_count = int(os.environ.get("LOADTEST_NAV", "0"))
    wait_time = constant(0)

    def on_start(self) -> None:
        self.number = next(_nav_numbers)
        route = STATE["route"]
        self.guard = WriteGuard(
            route=(route["start_anchor_id"], route["end_anchor_id"])
        )
        self.sign_in(STATE["nav_accounts"][self.number])
        self.step = 0
        self.offset = start_offset(self.number, len(TICKS))
        self.last_tick = None
        self.session_id = None
        self.open_app()
        self.start_trip(route)

    def open_app(self) -> None:
        self.get(f"/user/profiles/{self.user_id}", name="/user/profiles/[id]")
        self.get("/user/app-version")
        self.get("/navigation/sessions/active")
        self.read_lists()
        self.get("/map/anchor-point-connections")

    def start_trip(self, route: dict) -> None:
        self.write(
            "POST",
            "/route/routes/find_or_create",
            {
                "start_anchor_id": route["start_anchor_id"],
                "end_anchor_id": route["end_anchor_id"],
            },
        )
        stops = [
            route["start_anchor_id"],
            *(route.get("waypoint_anchor_ids") or []),
            route["end_anchor_id"],
        ]
        # The app asks for these in parallel.
        calls = [
            gevent.spawn(self.get, f"/map/anchor-points/{s}", "/map/anchor-points/[id]")
            for s in stops
        ] + [
            gevent.spawn(
                self.get,
                f"/map/anchor-points/{s}/connections",
                "/map/anchor-points/[id]/connections",
            )
            for s in stops[:-1]
        ]
        gevent.joinall(calls)
        response = self.write(
            "POST",
            "/navigation/sessions",
            {
                "user_id": self.user_id,
                "building_id": route.get("building_id"),
                "route_id": route["id"],
                "device_info": {"platform": "loadtest"},
            },
        )
        rows = response.json() if response.ok else []
        if rows:
            self.session_id = rows[0]["id"]
            self.guard.sessions.add(self.session_id)

    @task
    def tick(self) -> None:
        if not self.session_id:
            # The server refused the trip: keep trying, so a run against a
            # server that's down reaches the stop rule instead of sitting idle.
            gevent.sleep(1)
            self.start_trip(STATE["route"])
            return
        tick = TICKS[ping_pong_index(self.step, len(TICKS), self.offset)]
        self.step += 1
        gevent.sleep(CAPTURE_SECONDS)
        now = datetime.now(UTC).isoformat()
        fields = {
            "session_id": self.session_id,
            "latitude": str(tick["latitude"]),
            "longitude": str(tick["longitude"]),
            "accuracy": str(tick["accuracy"]),
            "gps_time": now,
        }
        if tick.get("heading") is not None:
            fields["heading"] = str(tick["heading"])
        self.guard.check("POST", PHOTO_ENDPOINT, fields)
        started = time.monotonic()
        response = self.client.post(
            PHOTO_ENDPOINT,
            data=fields,
            files={"photo": ("frame.jpg", tick["photo"], "image/jpeg")},
            headers=self.headers,
            name=PHOTO_ENDPOINT,
        )
        result = {}
        if response.ok:
            result = response.json()
        self.record(result, response.ok, time.monotonic() - started)
        log = {
            "session_id": self.session_id,
            "gps_lat": tick["latitude"],
            "gps_long": tick["longitude"],
            "gps_accuracy": tick["accuracy"],
            "heading": tick.get("heading"),
            "debug": {"loadtest": True},
        }
        if result:
            log |= {
                "corrected_lat": result.get("corrected_lat"),
                "corrected_long": result.get("corrected_long"),
                "correction_error": result.get("correction_error"),
                "anchor_match_id": result.get("anchor_match_id"),
                "confidence_score": result.get("confidence_score"),
            }
        # The app doesn't wait for this one (unawaited in navigation_screen.dart).
        gevent.spawn(self.write, "POST", "/navigation/logs", log)
        gevent.sleep(AFTER_TICK_SECONDS)

    def record(self, result: dict, ok: bool, seconds: float) -> None:
        now = time.monotonic()
        gap_ms = None if self.last_tick is None else (now - self.last_tick) * 1000
        self.last_tick = now
        debug = result.get("debug") or {}
        timing = debug.get("search_timing") or {}
        row = {
            "user": self.number,
            "ok": ok,
            "round_trip_ms": seconds * 1000,
            "gap_ms": gap_ms,
            "total_ms": debug.get("total_ms"),
            "embed_ms": timing.get("embed"),
            "qdrant_ms": timing.get("qdrant"),
            "matched": result.get("anchor_match_id") is not None,
        }
        with (RESULTS / "ticks.jsonl").open("a") as file:
            file.write(json.dumps(row) + "\n")
        if gap_ms is not None:
            self.environment.events.request.fire(
                request_type=TICK_TYPE,
                name="between photos",
                response_time=gap_ms,
                response_length=0,
                exception=None,
                context={},
            )

    def on_stop(self) -> None:
        if self.session_id:
            self.write(
                "PATCH",
                f"/navigation/sessions/{self.session_id}",
                {
                    "status": "completed",
                    "end_time": datetime.now(UTC).isoformat(),
                },
                name="/navigation/sessions/[id]",
            )


class EditingAdmin(Person):
    """An admin improving the map, in the sandbox only. Real data is only read."""

    fixed_count = int(os.environ.get("LOADTEST_ADMINS", "0"))
    wait_time = between(5, 15)

    def on_start(self) -> None:
        self.number = next(_admin_numbers)
        self.guard = WriteGuard(building_id=STATE["sandbox"]["building_id"])
        self.sign_in(STATE["admin_accounts"][self.number])
        self.created = 0
        self.points: list[dict] = []
        self.connected_upto = 0
        self.open_home()

    def open_home(self) -> None:
        """All of the home screen's lists together, as the app loads them."""
        paths = (
            "/map/places",
            "/map/buildings",
            "/map/anchor-points",
            "/map/anchor-point-photos",
            "/map/anchor-point-connections",
        )
        gevent.joinall([gevent.spawn(self.get, path) for path in paths])

    @task(3)
    def reload(self) -> None:
        self.open_home()

    @task(3)
    def create_point_with_photo(self) -> None:
        if self.created >= MAX_POINTS_PER_ADMIN:
            return
        sandbox = STATE["sandbox"]
        row = self.number + self.created // POINTS_PER_ROW
        step = self.created % POINTS_PER_ROW
        created = self.write(
            "POST",
            "/map/anchor-points",
            {
                "building_id": sandbox["building_id"],
                "location_type_id": 10,
                "latitude": sandbox["latitude"] + step * POINT_STEP_DEGREES,
                "longitude": sandbox["longitude"] + row * ROW_STEP_DEGREES,
                "floor": 0,
                "allow_nearby": True,
                "metadata": {"indoor": True},
            },
        )
        self.created += 1
        rows = created.json() if created.ok else []
        if not rows:
            return
        point = rows[0]
        self.guard.points.add(point["id"])
        self.points.append(point)
        self.upload_photo(point)
        self.open_home()

    def upload_photo(self, point: dict) -> None:
        self.guard.check("POST", "/map/anchor-points/upload-image")
        photo = random.choice(TICKS)["photo"]
        upload = self.client.post(
            "/map/anchor-points/upload-image",
            files={
                "file": (
                    f"loadtest-{self.number}-{time.monotonic_ns()}.jpg",
                    photo,
                    "image/jpeg",
                )
            },
            headers=self.headers,
            name="/map/anchor-points/upload-image",
        )
        if not upload.ok:
            return
        url = upload.json()["url"]
        with (RESULTS / "uploads.txt").open("a") as file:
            file.write(url + "\n")
        saved = self.write(
            "POST",
            f"/map/anchor-points/{point['id']}/photos",
            {"image_url": url, "heading": 0},
            name="/map/anchor-points/[id]/photos",
        )
        if saved.ok:
            point["photos"] = saved.json()

    @task(4)
    def connect_next(self) -> None:
        """Connect on map: the app draws the line and doesn't reload."""
        index = self.connected_upto + 1
        if index >= len(self.points):
            return
        self.connected_upto = index
        if index % POINTS_PER_ROW == 0:
            return  # A new row is too far from the last point of the old one.
        self.write(
            "POST",
            "/map/anchor-point-connections",
            {
                "anchor_point_a_id": self.points[index - 1]["id"],
                "anchor_point_b_id": self.points[index]["id"],
            },
        )

    @task(2)
    def rename(self) -> None:
        if not self.points:
            return
        point = random.choice(self.points)
        self.write(
            "PATCH",
            f"/map/anchor-points/{point['id']}",
            {"location_description": f"Punto {time.monotonic_ns() % 1000}"},
            name="/map/anchor-points/[id]",
        )
        self.open_home()

    @task(2)
    def verify_and_index(self) -> None:
        """What verifying costs: the model runs on each of the point's photos,
        in the service that answers users' photo searches."""
        pending = [p for p in self.points if p.get("photos") and not p.get("verified")]
        if not pending:
            return
        point = pending[0]
        point["verified"] = True
        response = self.write(
            "PATCH",
            f"/map/anchor-points/{point['id']}",
            {"status": "verified"},
            name="/map/anchor-points/[id]",
        )
        if not response.ok:
            return
        self.write(
            "POST",
            "/ai-training/index_anchor",
            {
                "anchor_point_id": point["id"],
                "latitude": point["latitude"],
                "longitude": point["longitude"],
                "building_id": point["building_id"],
                "photos": [
                    {
                        "photo_id": photo["id"],
                        "image_url": photo["image_url"],
                        "heading": photo.get("heading"),
                    }
                    for photo in point["photos"]
                ],
            },
        )
        self.open_home()


def _watch_for_trouble(environment, every_seconds: float) -> None:
    """Ends a run that's failing, rather than keep loading a struggling server."""
    answered = 0
    last_answer = time.monotonic()
    while True:
        gevent.sleep(every_seconds)
        entries = [
            entry
            for (name, method), entry in environment.stats.entries.items()
            if method != TICK_TYPE
        ]
        requests = sum(entry.num_requests for entry in entries)
        failures = sum(entry.num_failures for entry in entries)
        photo = environment.stats.entries.get((PHOTO_ENDPOINT, "POST"))
        photo_p95 = photo.get_current_response_time_percentile(0.95) if photo else None
        if requests > answered:
            answered = requests
            last_answer = time.monotonic()
        reason = stop_reason(
            requests,
            failures,
            photo_p95,
            silent_seconds=time.monotonic() - last_answer,
            memory_mb=latest_memory_mb(RESULTS / "server.csv"),
        )
        if reason:
            (RESULTS / "stop_reason.txt").write_text(reason + "\n")
            environment.runner.quit()
            return


@events.test_start.add_listener
def _start_watching(environment, **_kwargs) -> None:
    every = float(os.environ.get("LOADTEST_WATCH_SECONDS", "10"))
    gevent.spawn(_watch_for_trouble, environment, every)
