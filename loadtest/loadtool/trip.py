"""One trip's story from its logs (B3): where it stopped, what was said, how
photos and the heading did, and the likely problems, with when each happened.
Pure: trip_report.py fetches the rows, and the tests use made-up trips.

The rules for "likely problems" come from the field tests in docs/TUNING.md:
spinning and getting stuck (§10), pauses, and stretches no photo ever matched.
"""

import itertools
import math
import statistics
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime

# Turn cues: the ones that made people spin in Edificio C.
TURN_CUES = {"turn", "slow_turn"}
# Shown in the timeline; the periodic progress ("info") would drown them.
TIMELINE_CUES = {"turn", "slow_turn", "start_walking", "turn_ahead", "leg", "arrival"}

SPIN_CUES, SPIN_WINDOW_S, SPIN_MOVED_M = 3, 60, 10
STUCK_WINDOW_S, STUCK_PROGRESS_M = 60, 3
SILENCE_S = 30
PAUSE_S = 20
COMPASS_OFF_DEG, COMPASS_OFF_SHARE = 45, 0.2
# A stretch needs this many photos before "never matched" means something.
STRETCH_MIN_PHOTOS = 5


def _time(value: str) -> datetime:
    return datetime.fromisoformat(value)


def _meters(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat = math.radians((a[0] + b[0]) / 2)
    dy = (a[0] - b[0]) * 111_320
    dx = (a[1] - b[1]) * 111_320 * math.cos(lat)
    return math.hypot(dx, dy)


def clock(seconds: float) -> str:
    """Seconds since the trip started, as +m:ss."""
    seconds = max(0, round(seconds))
    return f"+{seconds // 60}:{seconds % 60:02d}"


@dataclass
class Problem:
    at_s: float
    kind: str
    detail: str


@dataclass
class TripSummary:
    id: str
    phone: str
    app_version: str
    status: str
    started: str
    duration_s: float
    arrived: bool
    ticks: int
    waypoints: list[tuple[float, int, int]] = field(default_factory=list)
    cue_counts: Counter = field(default_factory=Counter)
    timeline: list[tuple[float, str, str]] = field(default_factory=list)
    photos: int = 0
    matched: int = 0
    median_score: float | None = None
    failures: Counter = field(default_factory=Counter)
    median_correction_m: float | None = None
    trusted_share: float | None = None
    compass_off_share: float | None = None
    heading_sources: Counter = field(default_factory=Counter)
    gaps: list[tuple[float, float]] = field(default_factory=list)
    floor_events: list[tuple[float, str]] = field(default_factory=list)
    reports: list[tuple[float, str]] = field(default_factory=list)
    problems: list[Problem] = field(default_factory=list)


def _phone(device: dict) -> tuple[str, str]:
    model = " ".join(
        str(device[k]) for k in ("manufacturer", "model") if device.get(k)
    ).strip()
    if device.get("os_version"):
        model += f", Android {device['os_version']}"
    return (model or "not logged"), str(device.get("app_version") or "not logged")


def _spinning(turns: list[float], positions: list[tuple[float, tuple]]) -> list[float]:
    found, last = [], -math.inf
    for i in range(len(turns) - SPIN_CUES + 1):
        start, end = turns[i], turns[i + SPIN_CUES - 1]
        if end - start > SPIN_WINDOW_S or start < last + SPIN_WINDOW_S:
            continue
        where = [p for t, p in positions if start <= t <= end]
        moved = max((_meters(a, b) for a in where for b in where), default=0)
        if moved < SPIN_MOVED_M:
            found.append(start)
            last = start
    return found


def _stuck(progress: list[tuple[float, int, float]], arrived_at: float) -> list[float]:
    """Windows of STUCK_WINDOW_S on one stretch without STUCK_PROGRESS_M closer."""
    found, i = [], 0
    while i < len(progress):
        t, index, distance = progress[i]
        if t >= arrived_at:
            break
        later = next(
            (p for p in progress[i:] if p[0] - t >= STUCK_WINDOW_S),
            None,
        )
        if later is None:
            break
        same = [p for p in progress[i:] if p[0] <= later[0]]
        if (
            all(p[1] == index for p in same)
            and distance - min(p[2] for p in same) < STUCK_PROGRESS_M
        ):
            found.append(t)
            while i < len(progress) and progress[i][0] < t + STUCK_WINDOW_S:
                i += 1
            continue
        i += 1
    return found


def summarize(session: dict, logs: list[dict], reports: list[dict] = ()) -> TripSummary:
    logs = sorted(logs, key=lambda log: log["timestamp"])
    start = _time(session.get("start_time") or logs[0]["timestamp"])

    def since(value: str) -> float:
        return (_time(value) - start).total_seconds()

    end = session.get("end_time") or (logs[-1]["timestamp"] if logs else None)
    phone, version = _phone(session.get("device_info") or {})
    summary = TripSummary(
        id=session["id"],
        phone=phone,
        app_version=version,
        status=session.get("status") or "?",
        started=start.strftime("%Y-%m-%d %H:%M UTC"),
        duration_s=since(end) if end else 0,
        arrived=False,
        ticks=len(logs),
    )

    cues, events, positions, progress = [], [], [], []
    scores, corrections, trusted, compass_off = [], [], [], []
    stretch_photos: Counter = Counter()
    stretch_matched: Counter = Counter()
    for log in logs:
        debug = log.get("debug") or {}
        t = since(log["timestamp"])
        cues += [
            (since(c["at"]), c.get("type", "?"), c.get("text", ""))
            for c in debug.get("cues") or []
        ]
        events += [
            (since(e.get("at") or log["timestamp"]), e)
            for e in debug.get("events") or []
        ]
        if log.get("gps_lat") is not None and log.get("gps_long") is not None:
            positions.append((t, (log["gps_lat"], log["gps_long"])))
        if (
            debug.get("target_index") is not None
            and debug.get("target_distance_m") is not None
        ):
            progress.append((t, debug["target_index"], debug["target_distance_m"]))
        if debug.get("heading_reliable") is not None:
            trusted.append(bool(debug["heading_reliable"]))
        if debug.get("compass_vs_heading") is not None:
            compass_off.append(abs(debug["compass_vs_heading"]) > COMPASS_OFF_DEG)
        if debug.get("heading_source"):
            summary.heading_sources[debug["heading_source"]] += 1
        if debug.get("failure"):
            summary.failures[debug["failure"]] += 1
        if debug.get("correction") is not None or (debug.get("timing_ms") or {}).get(
            "correct"
        ):
            summary.photos += 1
            stretch_photos[debug.get("target_index")] += 1
            if log.get("anchor_match_id"):
                summary.matched += 1
                stretch_matched[debug.get("target_index")] += 1
                if log.get("confidence_score") is not None:
                    scores.append(log["confidence_score"])
        if log.get("correction_error") is not None:
            corrections.append(log["correction_error"])

    cues.sort(key=lambda c: c[0])
    events.sort(key=lambda e: e[0])
    summary.cue_counts = Counter(kind for _, kind, _ in cues)
    summary.timeline = [c for c in cues if c[1] in TIMELINE_CUES]
    summary.median_score = statistics.median(scores) if scores else None
    summary.median_correction_m = (
        statistics.median(corrections) if corrections else None
    )
    summary.trusted_share = sum(trusted) / len(trusted) if trusted else None
    summary.compass_off_share = (
        sum(compass_off) / len(compass_off) if compass_off else None
    )

    arrived_at = math.inf
    problems = summary.problems
    for t, event in events:
        kind = event.get("type")
        if kind in ("waypoint", "arrival"):
            summary.waypoints.append(
                (t, event.get("index", -1), event.get("skipped", 0))
            )
            if kind == "arrival":
                summary.arrived, arrived_at = True, min(arrived_at, t)
        elif kind == "stall":
            # The app repeats it while still stuck: one problem per minute.
            if any(p.kind == "stuck" and t - p.at_s < STUCK_WINDOW_S for p in problems):
                continue
            problems.append(
                Problem(
                    t,
                    "stuck",
                    f"no progress; compass {event.get('compass', '?')}°, said turn {event.get('turn', '?')}°",
                )
            )
        elif kind in ("floor_wait", "floor_detected", "floor_timeout"):
            summary.floor_events.append((t, kind))
            if kind == "floor_timeout":
                problems.append(
                    Problem(
                        t,
                        "floor timeout",
                        f"floor change to {event.get('to', '?')} not detected",
                    )
                )
        elif kind == "app_paused":
            problems.append(Problem(t, "pause", "the app went to the background"))
        elif kind == "gps_stale":
            problems.append(
                Problem(t, "stale GPS", f"no new fix for {event.get('age_s', '?')} s")
            )

    for a, b in itertools.pairwise(logs):
        gap = (_time(b["timestamp"]) - _time(a["timestamp"])).total_seconds()
        if gap > PAUSE_S:
            summary.gaps.append((since(a["timestamp"]), gap))
            problems.append(
                Problem(since(a["timestamp"]), "pause", f"no tick for {gap:.0f} s")
            )

    turns = [t for t, kind, _ in cues if kind in TURN_CUES]
    for t in _spinning(turns, positions):
        problems.append(
            Problem(
                t,
                "spinning",
                f"{SPIN_CUES}+ turn cues in {SPIN_WINDOW_S} s, raw GPS moved under {SPIN_MOVED_M} m",
            )
        )
    stalled = {round(p.at_s) for p in problems if p.kind == "stuck"}
    for t in _stuck(progress, arrived_at):
        if not any(abs(t - s) < STUCK_WINDOW_S for s in stalled):
            problems.append(
                Problem(
                    t,
                    "stuck",
                    f"under {STUCK_PROGRESS_M} m closer in {STUCK_WINDOW_S} s",
                )
            )

    said = [t for t, _, _ in cues if t < arrived_at]
    for a, b in itertools.pairwise(said):
        if b - a >= SILENCE_S:
            problems.append(
                Problem(a, "long silence", f"nothing said for {b - a:.0f} s")
            )

    for index, count in sorted(
        stretch_photos.items(), key=lambda kv: (kv[0] is None, kv[0])
    ):
        if (
            index is not None
            and count >= STRETCH_MIN_PHOTOS
            and not stretch_matched[index]
        ):
            first = (
                next(t for t, i, _ in progress if i == index)
                if any(i == index for _, i, _ in progress)
                else 0
            )
            problems.append(
                Problem(
                    first,
                    "no photo matches",
                    f"stretch to stop {index}: 0 of {count} photos",
                )
            )

    if (
        summary.compass_off_share is not None
        and summary.compass_off_share > COMPASS_OFF_SHARE
    ):
        problems.append(
            Problem(
                0,
                "compass disagreement",
                f"over {COMPASS_OFF_DEG}° off the heading on {summary.compass_off_share:.0%} of ticks",
            )
        )

    for report in reports:
        t = since(report["created_at"])
        summary.reports.append((t, report.get("instruction_text") or ""))
        problems.append(
            Problem(
                t,
                "reported wrong",
                f"{report.get('cue_type') or 'instruction'}: {report.get('instruction_text') or ''}"[
                    :90
                ],
            )
        )

    if not summary.arrived:
        problems.append(
            Problem(summary.duration_s, "not arrived", f"ended {summary.status}")
        )
    problems.sort(key=lambda p: p.at_s)
    return summary


def _share(part: int, whole: int) -> str:
    return f"{part / whole:.0%}" if whole else "—"


def render(s: TripSummary) -> str:
    def opt(value, fmt):
        return "—" if value is None else fmt.format(value)

    lines = [
        f"## Trip {s.id[:8]} ({s.started})",
        "",
        (
            f"- **Phone:** {s.phone}; app {s.app_version}. **{s.status}**, {clock(s.duration_s)[1:]} long, "
            f"{'arrived' if s.arrived else '**not arrived**'}, {s.ticks} ticks."
        ),
        "- **Stops:** "
        + (
            ", ".join(
                f"{index} at {clock(t)}" + (f" (skipped {skipped})" if skipped else "")
                for t, index, skipped in s.waypoints
            )
            or "none reached"
        ),
        f"- **Photos:** {s.matched} of {s.photos} matched ({_share(s.matched, s.photos)}), median score "
        f"{opt(s.median_score, '{:.2f}')}"
        + (
            f"; failures: {', '.join(f'{k} {v}' for k, v in s.failures.most_common())}"
            if s.failures
            else ""
        ),
        f"- **Correction:** median {opt(s.median_correction_m, '{:.1f} m')}.",
        f"- **Heading:** trusted on {opt(s.trusted_share, '{:.0%}')} of ticks; compass over "
        f"{COMPASS_OFF_DEG}° off on {opt(s.compass_off_share, '{:.0%}')}; "
        + (
            ", ".join(f"{k} {v}" for k, v in s.heading_sources.most_common())
            or "no source logged"
        ),
        "- **Said:** "
        + (", ".join(f"{k} {v}" for k, v in s.cue_counts.most_common()) or "nothing"),
    ]
    if s.floor_events:
        lines.append(
            "- **Floors:** " + ", ".join(f"{k} {clock(t)}" for t, k in s.floor_events)
        )
    lines += ["", "**Likely problems**", ""]
    lines += [
        f"- {clock(p.at_s)} **{p.kind}**: {p.detail}" for p in s.problems[:12]
    ] or ["- none found"]
    if len(s.problems) > 12:
        lines.append(f"- … and {len(s.problems) - 12} more")
    if s.timeline:
        lines += ["", "**Instructions**", ""]
        lines += [
            f"- {clock(t)} {kind}: {text}"[:110] for t, kind, text in s.timeline[:14]
        ]
        if len(s.timeline) > 14:
            lines.append(f"- … and {len(s.timeline) - 14} more")
    return "\n".join(lines)


def render_many(summaries: list[TripSummary]) -> str:
    lines = [
        "| Trip | Phone | Length | Arrived | Matched | Problems |",
        "|---|---|---:|---|---:|---|",
    ]
    for s in summaries:
        kinds = Counter(p.kind for p in s.problems)
        lines.append(
            f"| {s.id[:8]} | {s.phone} | {clock(s.duration_s)[1:]} | {'yes' if s.arrived else 'no'} "
            f"| {_share(s.matched, s.photos)} | {', '.join(f'{k} ×{v}' if v > 1 else k for k, v in kinds.items()) or '—'} |"
        )
    return "\n".join(lines + [""] + ["\n\n".join(render(s) for s in summaries)])
