import json

from loadtool.report import (
    percentile,
    read_stats,
    render_run,
    stop_reason,
    summarize_ticks,
)
from loadtool.sampling import memory_mb, parse_stats_line


def test_stops_on_too_many_errors():
    assert "errors" in stop_reason(100, 6, None)


def test_keeps_going_at_few_errors_or_too_little_data():
    assert stop_reason(100, 5, None) is None
    assert stop_reason(10, 10, None) is None


def test_stops_on_very_slow_photos():
    assert "photo p95" in stop_reason(100, 0, 15_001)
    assert stop_reason(100, 0, 15_000) is None


def test_percentile():
    assert percentile([1, 2, 3, 4], 0.5) == 2
    assert percentile([1, 2, 3, 4], 0.95) == 4
    assert percentile([], 0.5) is None


def _write_ticks(path):
    rows = [
        {
            "ok": True,
            "gap_ms": 3000,
            "total_ms": 900,
            "embed_ms": 450,
            "qdrant_ms": 350,
            "matched": True,
        },
        {
            "ok": True,
            "gap_ms": 5000,
            "total_ms": 1100,
            "embed_ms": 600,
            "qdrant_ms": 400,
            "matched": False,
        },
        {"ok": False, "gap_ms": None, "matched": False},
    ]
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))


def test_summarizes_what_users_feel_and_where_time_went(tmp_path):
    ticks = tmp_path / "ticks.jsonl"
    _write_ticks(ticks)
    summary = summarize_ticks(ticks)
    assert summary["ticks"] == 3
    assert summary["answered"] == 2
    assert summary["matched_share"] == 0.5
    assert summary["gap_p95_ms"] == 5000
    assert summary["server_p50_ms"] == 900
    assert summary["embed_p95_ms"] == 600


STATS = """Type,Name,Request Count,Failure Count,Median Response Time,Average Response Time,Min Response Time,Max Response Time,Average Content Size,Requests/s,Failures/s,50%,66%,75%,80%,90%,95%,98%,99%,99.9%,99.99%,100%
POST,/positioning/correct_position,100,2,900,950,500,3000,500,3.3,0,900,1000,1000,1100,1200,1500,2000,2500,3000,3000,3000
TICK,between photos,99,0,3000,3100,2500,6000,0,3.3,0,3000,3000,3100,3200,3500,4000,5000,6000,6000,6000,6000
,Aggregated,199,2,900,950,500,6000,250,6.6,0,1000,2000,3000,3000,3100,3500,4000,5000,6000,6000,6000
"""


def test_reads_locust_stats_per_endpoint(tmp_path):
    path = tmp_path / "run_stats.csv"
    path.write_text(STATS)
    rows = read_stats(path)
    assert [r["name"] for r in rows] == [
        "/positioning/correct_position",
        "between photos",
    ]
    assert rows[0]["failures"] == 2
    assert rows[0]["p95"] == 1500


def test_renders_a_run(tmp_path):
    (tmp_path / "run_stats.csv").write_text(STATS)
    _write_ticks(tmp_path / "ticks.jsonl")
    (tmp_path / "stop_reason.txt").write_text("errors at 9%\n")
    (tmp_path / "run_failures.csv").write_text(
        "Method,Name,Error,Occurrences\nPOST,/x,429 Too Many,4\n"
    )
    (tmp_path / "server.csv").write_text(
        "time,name,cpu_percent,mem_mb\n1,ai-training,150,900\n2,ai-training,50,950\n"
    )
    text = render_run("users-10", tmp_path)
    assert "Stopped early: errors at 9%" in text
    assert "POST /positioning/correct_position | 100 | 2 | 0.90 s | 1.50 s" in text
    assert "between photos | 99" not in text
    assert "Between photos: 3.00 s p50, 5.00 s p95" in text
    assert "4 × /x: 429 Too Many" in text
    assert "| ai-training | 100% | 150% | 950 MB |" in text


def test_reads_docker_stats():
    row = parse_stats_line(
        '{"Name":"4u-ai-training-1","CPUPerc":"153.20%","MemUsage":"1.5GiB / 3.8GiB"}'
    )
    assert row == {"name": "4u-ai-training-1", "cpu_percent": 153.2, "mem_mb": 1536}
    assert parse_stats_line("not json") is None
    assert memory_mb("312.5MiB / 3.8GiB") == 312.5
