"""Runs the real locustfile, as a subprocess, against a local stub. Nothing here
reaches a real server. It proves the scenario only sends what the guards allow,
and that the stop rule ends a failing run."""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

import run
from loadtool.config import ROOT

ROUTE = {
    "id": "route-1",
    "building_id": "real-building",
    "start_anchor_id": "a",
    "end_anchor_id": "b",
    "waypoint_anchor_ids": [],
}


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _answer(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        path = self.path.split("?")[0]
        if path == "/ai-training/index_anchor":
            self.server.indexed.append(json.loads(body))
        self.server.seen.append((self.command, path))
        if self.server.fail and path != "/auth/v1/token":
            self._answer(500, {"detail": "down"})
        elif path == "/auth/v1/token":
            self._answer(200, {"access_token": "token"})
        elif path == "/navigation/sessions" and self.command == "POST":
            self._answer(200, [{"id": "trip-1"}])
        elif path == "/positioning/correct_position":
            self._answer(
                200,
                {
                    "server_busy": self.server.busy,
                    "corrected_lat": 6.2,
                    "corrected_long": -75.5,
                    "correction_error": 3,
                    "anchor_match_id": "a",
                    "confidence_score": 0.5,
                    "debug": {
                        "total_ms": 900,
                        "search_timing": {"embed": 450, "qdrant": 350},
                    },
                },
            )
        elif path == "/map/anchor-points" and self.command == "POST":
            self.server.points += 1
            self._answer(
                200,
                [
                    {
                        "id": f"mine-{self.server.points}",
                        "latitude": 4.0,
                        "longitude": -71.5,
                        "building_id": "sandbox-building",
                    }
                ],
            )
        elif path == "/map/anchor-points/upload-image":
            self._answer(200, {"url": "http://stub/photo.jpg"})
        elif path.endswith("/photos") and self.command == "POST":
            self._answer(200, [{"id": "photo-1", "image_url": "http://stub/photo.jpg"}])
        else:
            self._answer(200, [])

    do_GET = do_POST = do_PATCH = do_DELETE = _handle


@pytest.fixture
def stub():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
    server.seen = []
    server.points = 0
    server.fail = False
    server.indexed = []
    server.busy = False
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server
    server.shutdown()


def write_state(tmp_path, url):
    frame = tmp_path / "frame.jpg"
    frame.write_bytes(b"not a real photo")
    state = tmp_path / "state.json"
    state.write_text(
        json.dumps(
            {
                "app_version": "0.5.6",
                "api_url": url,
                "supabase_url": url,
                "publishable_key": "key",
                "route": ROUTE,
                "trips": [
                    {
                        "ticks": [
                            {
                                "latitude": 6.2,
                                "longitude": -75.5,
                                "accuracy": 5,
                                "heading": None,
                                "frame": str(frame),
                            }
                        ]
                    }
                ],
                "nav_accounts": [{"id": "u1", "email": "n", "password": "p"}],
                "admin_accounts": [{"id": "a1", "email": "a", "password": "p"}],
                "sandbox": {
                    "building_id": "sandbox-building",
                    "latitude": 4.0,
                    "longitude": -71.5,
                },
            }
        )
    )
    return state


def run_locust(tmp_path, url, nav, admins, seconds):
    state = write_state(tmp_path, url)
    return subprocess.run(
        [
            sys.executable,
            "-m",
            "locust",
            "-f",
            "locustfile.py",
            "--headless",
            "--users",
            str(nav + admins),
            "--spawn-rate",
            "10",
            "--run-time",
            f"{seconds}s",
            "--stop-timeout",
            "5",
            "--csv",
            str(tmp_path / "run"),
            "--only-summary",
        ],
        check=False,
        cwd=ROOT,
        env={
            **os.environ,
            "LOADTEST_STATE": str(state),
            "LOADTEST_RESULTS": str(tmp_path),
            "LOADTEST_NAV": str(nav),
            "LOADTEST_ADMINS": str(admins),
            "LOADTEST_CAPTURE_SECONDS": "0",
            "LOADTEST_WATCH_SECONDS": "1",
            "LOADTEST_ADMIN_WAIT_SCALE": "0.02",
            "LOADTEST_PAUSED_TICK_SECONDS": "1",
        },
        capture_output=True,
        text=True,
        timeout=90,
    )


ALLOWED_WRITES = [
    r"POST /auth/v1/token",
    r"POST /route/routes/find_or_create",
    r"POST /navigation/sessions",
    r"PATCH /navigation/sessions/trip-1",
    r"POST /navigation/logs",
    r"POST /positioning/correct_position",
    r"POST /map/anchor-points",
    r"POST /map/anchor-points/upload-image",
    r"POST /map/anchor-points/mine-\d+/photos",
    r"PATCH /map/anchor-points/mine-\d+",
    r"POST /map/anchor-point-connections",
    r"POST /ai-training/index_anchor",
]


def test_a_mixed_run_only_writes_what_it_may_and_records_results(tmp_path, stub):
    url = f"http://127.0.0.1:{stub.server_address[1]}"
    result = run_locust(tmp_path, url, nav=1, admins=1, seconds=12)
    assert "UnsafeWrite" not in result.stderr, result.stderr[-2000:]
    assert "Traceback" not in result.stderr, result.stderr[-2000:]

    writes = {f"{m} {p}" for m, p in stub.seen if m != "GET"}
    for write in writes:
        assert any(re.fullmatch(p, write) for p in ALLOWED_WRITES), write
    assert not any(m == "DELETE" for m, _ in stub.seen)

    # The user's trip really ran, and ended.
    assert "POST /positioning/correct_position" in writes
    assert "POST /navigation/logs" in writes
    assert "PATCH /navigation/sessions/trip-1" in writes
    # The admin read the five lists.
    reads = {p for m, p in stub.seen if m == "GET"}
    assert "/map/anchor-point-photos" in reads

    ticks = [
        json.loads(line) for line in (tmp_path / "ticks.jsonl").read_text().splitlines()
    ]
    assert ticks[0]["embed_ms"] == 450
    assert ticks[0]["matched"] is True
    assert (tmp_path / "run_stats.csv").exists()
    assert not (tmp_path / "stop_reason.txt").exists()


def test_a_failing_server_stops_the_run(tmp_path, stub):
    stub.fail = True
    url = f"http://127.0.0.1:{stub.server_address[1]}"
    run_locust(tmp_path, url, nav=1, admins=0, seconds=40)
    reason = (tmp_path / "stop_reason.txt").read_text()
    assert "errors" in reason


def test_a_busy_answer_pauses_photos_but_not_logs(tmp_path, stub):
    stub.busy = True
    url = f"http://127.0.0.1:{stub.server_address[1]}"
    run_locust(tmp_path, url, nav=1, admins=0, seconds=14)
    photos = sum(p == "/positioning/correct_position" for _, p in stub.seen)
    logs = sum(p == "/navigation/logs" for _, p in stub.seen)
    # Without the pause, about one a second. With it, about one every 5-7 s.
    assert 1 <= photos <= 4
    assert logs > photos


def test_a_verified_point_indexes_all_its_photos(tmp_path, stub):
    url = f"http://127.0.0.1:{stub.server_address[1]}"
    run_locust(tmp_path, url, nav=0, admins=1, seconds=10)
    assert stub.indexed
    assert {len(request["photos"]) for request in stub.indexed} == {3}


def test_a_frozen_server_stops_the_run_and_skips_the_next_step(tmp_path, monkeypatch):
    """The real run.py and locust against a server that accepts connections and
    never answers, which is what the frozen server did."""
    held = []
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(50)

    def accept_and_hold():
        while True:
            held.append(server.accept())

    threading.Thread(target=accept_and_hold, daemon=True).start()
    url = f"http://127.0.0.1:{server.getsockname()[1]}"

    monkeypatch.setattr(
        run, "SAMPLER", [sys.executable, "-c", "import time; time.sleep(600)"]
    )
    monkeypatch.setattr(run, "PAUSE_SECONDS", 0)
    monkeypatch.setenv("LOADTEST_REQUEST_TIMEOUT", "300")
    monkeypatch.setenv("LOADTEST_SILENT_SECONDS", "3")
    monkeypatch.setenv("LOADTEST_WATCH_SECONDS", "1")

    root = tmp_path / "results"
    root.mkdir()
    state = write_state(tmp_path, url)
    started = time.monotonic()
    run.run_steps([("first", 1, 1, 5), ("second", 1, 1, 5)], state, root, ["report"])

    # Well before the 5 minutes the step would otherwise run.
    assert time.monotonic() - started < 60
    assert "no answers" in (root / "first" / "stop_reason.txt").read_text()
    assert not (root / "second").exists()
    assert "first" in (root / "report.md").read_text()
