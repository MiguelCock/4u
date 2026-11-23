"""A whole test round in one report (B5, B2): how trips went per campus and
app version, what each phone has, and the SUS score. Pure: round_report.py
fetches the trips, and the tests use made-up summaries.

"Lost" is a trip with a problem from LOST_KINDS (loadtool/trip.py's rules):
spinning in place or getting no closer. Phones are listed by model, which
says nothing about who carried them.
"""

import csv
import statistics
from collections import defaultdict
from collections.abc import Iterable

from loadtool.trip import TripSummary, clock

LOST_KINDS = {"spinning", "stuck"}
SUS_ITEMS = 10


def _median(values: Iterable[float | None]) -> float | None:
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def _pct(part: int, whole: int) -> str:
    return f"{part}/{whole} ({part / whole:.0%})" if whole else "—"


def _fmt(value: float | None, unit: str = "", digits: int = 1) -> str:
    return "—" if value is None else f"{value:.{digits}f}{unit}"


def _yes(values: list[bool | None]) -> str:
    known = [v for v in values if v is not None]
    if not known:
        return "not logged"
    return "yes" if all(known) else ("no" if not any(known) else "some trips")


def lost(summary: TripSummary) -> bool:
    return any(p.kind in LOST_KINDS for p in summary.problems)


def by_campus_version(summaries: list[TripSummary]) -> list[dict]:
    groups = defaultdict(list)
    for s in summaries:
        groups[(s.campus, s.app_version)].append(s)
    rows = []
    for (campus, version), trips in sorted(groups.items()):
        photos = sum(s.photos for s in trips)
        rows.append(
            {
                "campus": campus,
                "version": version,
                "trips": len(trips),
                "arrived": sum(s.arrived for s in trips),
                "arrival_s": _median(s.arrival_s for s in trips),
                "matched": sum(s.matched for s in trips),
                "photos": photos,
                "correction_m": _median(s.median_correction_m for s in trips),
                "lost": sum(lost(s) for s in trips),
                "lost_events": sum(
                    1 for s in trips for p in s.problems if p.kind in LOST_KINDS
                ),
            }
        )
    return rows


def by_phone(summaries: list[TripSummary]) -> list[dict]:
    groups = defaultdict(list)
    for s in summaries:
        groups[s.phone].append(s)
    rows = []
    for phone, trips in sorted(groups.items()):
        rows.append(
            {
                "phone": phone,
                "versions": ", ".join(sorted({s.app_version for s in trips})),
                "trips": len(trips),
                "gyroscope": _yes([s.has_gyroscope for s in trips]),
                "barometer": _yes([s.has_barometer for s in trips]),
                "compass_off": _median(s.compass_off_share for s in trips),
                "gps_accuracy_m": _median(s.gps_accuracy_m for s in trips),
                "capture_s": _median(s.capture_s for s in trips),
                "arrived": sum(s.arrived for s in trips),
            }
        )
    return rows


def sus_score(answers: list[int]) -> float:
    """The standard System Usability Scale score, 0-100: odd items count
    (answer - 1), even items (5 - answer), the sum times 2.5."""
    if len(answers) != SUS_ITEMS or any(not 1 <= a <= 5 for a in answers):
        raise ValueError(f"SUS needs {SUS_ITEMS} answers from 1 to 5, got {answers}")
    total = sum((a - 1) if i % 2 == 0 else (5 - a) for i, a in enumerate(answers))
    return total * 2.5


def read_sus(path: str) -> list[float]:
    """One row per participant: columns q1..q10, any others ignored (a code,
    never a name)."""
    with open(path, newline="") as file:
        return [
            sus_score([int(row[f"q{i}"]) for i in range(1, SUS_ITEMS + 1)])
            for row in csv.DictReader(file)
        ]


def render_round(summaries: list[TripSummary], sus: list[float] | None = None) -> str:
    lines = [
        "## By campus and app version",
        "",
        "| Campus | Version | Trips | Arrived | Time to arrive | Photos matched | Median correction | Got lost |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for r in by_campus_version(summaries):
        arrival = clock(r["arrival_s"])[1:] if r["arrival_s"] is not None else "—"
        lines.append(
            f"| {r['campus']} | {r['version']} | {r['trips']} | {_pct(r['arrived'], r['trips'])} "
            f"| {arrival} | {_pct(r['matched'], r['photos'])} | {_fmt(r['correction_m'], ' m')} "
            f"| {_pct(r['lost'], r['trips'])}, {r['lost_events']} times |"
        )
    lines += [
        "",
        "## By phone (device matrix)",
        "",
        "| Phone | App versions | Trips | Gyroscope | Barometer | Compass off | GPS accuracy | Photo capture | Arrived |",
        "|---|---|---:|---|---|---:|---:|---:|---:|",
    ]
    for r in by_phone(summaries):
        off = "—" if r["compass_off"] is None else f"{r['compass_off']:.0%}"
        lines.append(
            f"| {r['phone']} | {r['versions']} | {r['trips']} | {r['gyroscope']} | {r['barometer']} "
            f"| {off} | {_fmt(r['gps_accuracy_m'], ' m')} | {_fmt(r['capture_s'], ' s', 2)} "
            f"| {_pct(r['arrived'], r['trips'])} |"
        )
    lines += ["", "## SUS", ""]
    if sus:
        lines.append(
            f"Mean {statistics.mean(sus):.1f}, median {statistics.median(sus):.1f}, "
            f"n = {len(sus)} (68 is the usual average)."
        )
    else:
        lines.append("No answers given (`--sus answers.csv`).")
    return "\n".join(lines)
