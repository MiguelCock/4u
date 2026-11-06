"""Turns a run's files into numbers: the stop rule, and the summary tables."""

import csv
import json
import math
import os
from pathlib import Path

# Stop a run rather than hammer a server that's already failing.
STOP_ERROR_RATE = 0.05
STOP_PHOTO_P95_MS = 15_000
STOP_MIN_REQUESTS = 30
# No answers at all: the server has stopped responding (it froze this way once,
# at 10 users, and needed a reboot).
STOP_SILENT_SECONDS = float(os.environ.get("LOADTEST_SILENT_SECONDS", "45"))
# Containers' total, of the server's 3839 MB with no swap. At about 3200 MB it
# froze. One 14 s sample has jumped 1000 MB, so stop well before that.
STOP_MEMORY_MB = 2800


def stop_reason(
    requests: int,
    failures: int,
    photo_p95_ms: float | None,
    silent_seconds: float = 0,
    memory_mb: float | None = None,
) -> str | None:
    """Why a run should stop now, or None."""
    if silent_seconds >= STOP_SILENT_SECONDS:
        return f"no answers from the server for {silent_seconds:.0f} s"
    if memory_mb is not None and memory_mb >= STOP_MEMORY_MB:
        return f"containers using {memory_mb:.0f} MB of memory"
    if requests >= STOP_MIN_REQUESTS and failures / requests > STOP_ERROR_RATE:
        return f"errors at {failures / requests:.0%} ({failures} of {requests})"
    if photo_p95_ms is not None and photo_p95_ms > STOP_PHOTO_P95_MS:
        return f"photo p95 at {photo_p95_ms / 1000:.1f} s"
    return None


def latest_memory_mb(path: Path) -> float | None:
    """All containers' memory at the latest sample of a server.csv."""
    if not path.exists():
        return None
    with path.open(newline="") as file:
        latest = {row["name"]: float(row["mem_mb"]) for row in csv.DictReader(file)}
    return sum(latest.values()) if latest else None


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[index]


def read_stats(path: Path) -> list[dict]:
    """Locust's *_stats.csv, per endpoint, without its Aggregated row."""
    rows = []
    with path.open(newline="") as file:
        for row in csv.DictReader(file):
            if row["Name"] == "Aggregated":
                continue
            rows.append(
                {
                    "type": row["Type"],
                    "name": row["Name"],
                    "requests": int(row["Request Count"]),
                    "failures": int(row["Failure Count"]),
                    "p50": float(row["50%"] or 0),
                    "p95": float(row["95%"] or 0),
                    "p99": float(row["99%"] or 0),
                }
            )
    return rows


def read_failures(path: Path) -> list[dict]:
    """Locust's *_failures.csv: what failed, and how often, 429s included."""
    if not path.exists():
        return []
    with path.open(newline="") as file:
        return [
            {
                "name": row["Name"],
                "error": row["Error"],
                "count": int(row["Occurrences"]),
            }
            for row in csv.DictReader(file)
        ]


def summarize_ticks(path: Path) -> dict:
    """From ticks.jsonl: the gap between photos users feel, how often a photo
    matched, and where the server's time went."""
    ticks = []
    if path.exists():
        ticks = [json.loads(line) for line in path.read_text().splitlines() if line]
    answered = [t for t in ticks if t.get("ok")]
    field = lambda name: [t[name] for t in answered if t.get(name) is not None]
    gaps = [t["gap_ms"] for t in ticks if t.get("gap_ms") is not None]

    def p(values, fraction):
        result = percentile(values, fraction)
        return None if result is None else round(result)

    return {
        "ticks": len(ticks),
        "answered": len(answered),
        "matched_share": (
            sum(1 for t in answered if t.get("matched")) / len(answered)
            if answered
            else None
        ),
        "busy_share": (
            sum(1 for t in answered if t.get("busy")) / len(answered)
            if answered
            else None
        ),
        "gap_p50_ms": p(gaps, 0.5),
        "gap_p95_ms": p(gaps, 0.95),
        "server_p50_ms": p(field("total_ms"), 0.5),
        "server_p95_ms": p(field("total_ms"), 0.95),
        "embed_p50_ms": p(field("embed_ms"), 0.5),
        "embed_p95_ms": p(field("embed_ms"), 0.95),
        "qdrant_p50_ms": p(field("qdrant_ms"), 0.5),
        "qdrant_p95_ms": p(field("qdrant_ms"), 0.95),
    }


def _ms(value) -> str:
    return "—" if value is None else f"{value / 1000:.2f} s"


def render_run(name: str, run_dir: Path) -> str:
    lines = [f"### {name}", ""]
    stopped = run_dir / "stop_reason.txt"
    if stopped.exists():
        lines += [f"**Stopped early: {stopped.read_text().strip()}.**", ""]
    ticks = summarize_ticks(run_dir / "ticks.jsonl")
    if ticks["ticks"]:
        matched = ticks["matched_share"]
        lines += [
            (
                f"- Between photos: {_ms(ticks['gap_p50_ms'])} p50, "
                f"{_ms(ticks['gap_p95_ms'])} p95, over {ticks['ticks']} photos"
            ),
            (
                f"- Server time: {_ms(ticks['server_p50_ms'])} p50, "
                f"{_ms(ticks['server_p95_ms'])} p95"
            ),
            (
                f"- Model: {_ms(ticks['embed_p50_ms'])} p50, "
                f"{_ms(ticks['embed_p95_ms'])} p95. Qdrant: "
                f"{_ms(ticks['qdrant_p50_ms'])} p50, {_ms(ticks['qdrant_p95_ms'])} p95"
            ),
            "- Photos with a match: " + ("—" if matched is None else f"{matched:.0%}"),
            "- Photos refused as busy: "
            + ("—" if ticks["busy_share"] is None else f"{ticks['busy_share']:.0%}"),
            "",
        ]
    stats_file = run_dir / "run_stats.csv"
    if stats_file.exists():
        lines += [
            "| Endpoint | Requests | Errors | p50 | p95 | p99 |",
            "|---|---:|---:|---:|---:|---:|",
        ]
        for row in read_stats(stats_file):
            if row["type"] == "TICK":
                continue
            lines.append(
                f"| {row['type']} {row['name']} | {row['requests']} "
                f"| {row['failures']} | {_ms(row['p50'])} | {_ms(row['p95'])} "
                f"| {_ms(row['p99'])} |"
            )
        lines.append("")
    failures = read_failures(run_dir / "run_failures.csv")
    if failures:
        lines += ["Errors:", ""]
        lines += [f"- {f['count']} × {f['name']}: {f['error']}" for f in failures]
        lines.append("")
    samples = run_dir / "server.csv"
    if samples.exists():
        lines += [render_server(samples), ""]
    return "\n".join(lines)


def render_server(path: Path) -> str:
    """Peak and average CPU and memory per container, from sample_server.py."""
    by_name: dict[str, list[tuple[float, float]]] = {}
    with path.open(newline="") as file:
        for row in csv.DictReader(file):
            by_name.setdefault(row["name"], []).append(
                (float(row["cpu_percent"]), float(row["mem_mb"]))
            )
    lines = [
        "| Container | CPU average | CPU peak | Memory peak |",
        "|---|---:|---:|---:|",
    ]
    for name, values in sorted(
        by_name.items(), key=lambda item: -max(v[0] for v in item[1])
    ):
        cpu = [v[0] for v in values]
        lines.append(
            f"| {name} | {sum(cpu) / len(cpu):.0f}% | {max(cpu):.0f}% "
            f"| {max(v[1] for v in values):.0f} MB |"
        )
    return "\n".join(lines)
