"""trip.py on made-up trips shaped like docs/TUNING.md §10's: each must give
exactly its own likely problems. No real trip is used: those are people's walks."""

from datetime import UTC, datetime, timedelta

from loadtool.trip import clock, render, render_many, summarize

START = datetime(2026, 11, 5, 14, 0, tzinfo=UTC)
LAT, LNG = 3.342, -76.53


def at(seconds: float) -> str:
    return (START + timedelta(seconds=seconds)).isoformat()


def tick(
    seconds,
    *,
    north_m=0.0,
    target=0,
    distance=20.0,
    cues=(),
    events=(),
    photo=True,
    match=True,
    **debug,
):
    return {
        "id": f"log-{seconds}",
        "timestamp": at(seconds),
        "gps_lat": LAT + north_m / 111_320,
        "gps_long": LNG,
        "anchor_match_id": "anchor" if photo and match else None,
        "confidence_score": 0.4 if photo and match else None,
        "correction_error": 1.5 if photo and match else None,
        "debug": {
            "target_index": target,
            "target_distance_m": distance,
            "heading_reliable": True,
            "compass_vs_heading": 5.0,
            "heading_source": "gyro",
            "cues": [
                {"at": at(seconds), "type": kind, "text": text} for kind, text in cues
            ],
            "events": [{"at": at(seconds), **event} for event in events],
            **({"timing_ms": {"capture": 400, "correct": 900}} if photo else {}),
            **debug,
        },
    }


def session(status="completed", device=None, end=None):
    return {
        "id": "a1b2c3d4-0000-0000-0000-000000000000",
        "status": status,
        "start_time": at(0),
        "end_time": at(end) if end is not None else None,
        "device_info": device or {"platform": "android"},
    }


def walk(seconds=60, *, arrive=True, speak_every=10):
    """A clean trip: walking 1 m/s towards stop 1, a cue every few seconds, arriving."""
    logs = []
    for s in range(0, seconds + 1, 2):
        cues = [("info", f"{seconds - s} steps")] if s % speak_every == 0 else []
        if s == 0:
            cues = [("start_walking", "Walk forward")]
        events = (
            [{"type": "arrival", "index": 1, "skipped": 0}]
            if arrive and s == seconds
            else []
        )
        logs.append(
            tick(s, north_m=s, target=1, distance=seconds - s, cues=cues, events=events)
        )
    return logs


def kinds(summary):
    return sorted({p.kind for p in summary.problems})


def test_a_clean_trip_has_no_problems():
    summary = summarize(session(end=60), walk())
    assert kinds(summary) == []
    assert summary.arrived
    assert summary.matched == summary.photos == 31
    assert summary.waypoints == [(60, 1, 0)]
    assert "none found" in render(summary)


def test_spinning_is_turn_cues_while_standing_still():
    # Edificio C: GPS jumping on the spot, the app saying turn, turn, turn.
    logs = walk()
    logs += [
        tick(
            70 + 4 * i,
            north_m=60 + (i % 2) * 3,
            target=1,
            distance=0.5,
            cues=[("turn", "Turn left")],
        )
        for i in range(4)
    ]
    logs[-1]["debug"]["events"] = []
    for log in logs:
        log["debug"]["events"] = [
            e for e in log["debug"]["events"] if e["type"] != "arrival"
        ]
    logs.append(
        tick(
            90,
            north_m=60,
            target=1,
            distance=0,
            events=[{"type": "arrival", "index": 1}],
        )
    )
    summary = summarize(session(end=90), logs)
    assert kinds(summary) == ["spinning"]
    assert (
        clock(next(p for p in summary.problems if p.kind == "spinning").at_s) == "+1:10"
    )


def test_stuck_is_no_progress_and_the_stall_event():
    # Samán: GPS barely moving, no trusted heading, the app's stall cue.
    logs = [
        tick(
            s,
            target=2,
            distance=30 - (s % 4) * 0.2,
            cues=[("info", "…")] if s % 10 == 0 else [],
        )
        for s in range(0, 91, 2)
    ]
    logs[10]["debug"]["events"] = [
        {"type": "stall", "compass": 200, "bearing": 90, "turn": -110}
    ]
    summary = summarize(session(status="abandoned", end=90), logs)
    assert kinds(summary) == ["not arrived", "stuck"]
    # The stall event, not a second "stuck" for the same minute.
    assert next(p.at_s for p in summary.problems if p.kind == "stuck") == 20


def test_a_pause_is_a_gap_between_ticks_and_the_app_leaving():
    logs = walk()
    for log in logs:
        log["timestamp"] = at(
            (datetime.fromisoformat(log["timestamp"]) - START).total_seconds()
            + (50 if log["timestamp"] > at(30) else 0)
        )
        for item in log["debug"]["cues"] + log["debug"]["events"]:
            item["at"] = log["timestamp"]
    logs[15]["debug"]["events"].append({"type": "app_paused"})
    summary = summarize(session(end=110), logs)
    assert "pause" in kinds(summary)
    assert any("no tick for 52 s" in p.detail for p in summary.problems)


def test_a_stretch_no_photo_ever_matched():
    logs = walk()
    for log in logs[:12]:
        log["anchor_match_id"] = None
        log["debug"]["target_index"] = 0
    summary = summarize(session(end=60), logs)
    assert kinds(summary) == ["no photo matches"]
    assert "stop 0: 0 of 12" in summary.problems[0].detail


def test_silence_compass_floor_and_reports():
    logs = walk(speak_every=40)
    for log in logs[:20]:
        log["debug"]["compass_vs_heading"] = 85.0
    logs[5]["debug"]["events"].append({"type": "floor_timeout", "to": 2})
    reports = [
        {"created_at": at(20), "cue_type": "turn", "instruction_text": "Turn right"}
    ]
    summary = summarize(session(end=60), logs, reports)
    assert kinds(summary) == [
        "compass disagreement",
        "floor timeout",
        "long silence",
        "reported wrong",
    ]


def test_the_phone_from_b2s_device_info():
    device = {
        "platform": "android",
        "manufacturer": "samsung",
        "model": "SM-A245M",
        "os_version": "14",
        "app_version": "0.6.0",
    }
    summary = summarize(session(end=60, device=device), walk())
    assert summary.phone == "samsung SM-A245M, Android 14"
    assert summary.app_version == "0.6.0"
    assert summarize(session(end=60), walk()).phone == "not logged"


def test_several_trips_start_with_a_table():
    text = render_many(
        [
            summarize(session(end=60), walk()),
            summarize(session(end=60), walk(arrive=False)),
        ]
    )
    assert text.splitlines()[0].startswith("| Trip | Phone")
    assert "| no |" in text
    assert text.count("## Trip") == 2
