import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from replay import COMPARE_COLUMNS, Route, _Plane, compare_table, walk_scores

LAT, LNG = 6.2, -75.6
# 1 m north in latitude degrees.
M = 1 / 111_320


def _walk(norths, speeds):
    """Logs and replayed positions: tick i is norths[i] m north of the
    start, on a straight route due north."""
    # One photo every 2 s.
    logs = [
        {
            "id": f"t{i}",
            "debug": {
                "gps_speed": s,
                "photo_at": f"2026-11-13T18:00:{2 * i:02d}+00:00",
            },
        }
        for i, s in enumerate(speeds)
    ]
    positions = {f"t{i}": (LAT + n * M, LNG) for i, n in enumerate(norths)}
    plane = _Plane(LAT, LNG)
    route = Route([plane.xy(LAT, LNG), plane.xy(LAT + 100 * M, LNG)])
    return logs, plane, route, positions


def test_jumps_are_split_by_the_phones_speed():
    logs, plane, route, positions = _walk(
        [0, 1, 2, 10, 10.5, 10.5], [0.0, 1.2, 1.2, 1.2, 0.1, 0.1]
    )
    s = walk_scores(logs, plane, route, positions)
    assert round(s["all_max"], 2) == 8.0
    assert round(s["walking_max"], 2) == 8.0
    # 8 m in 2 s at 1.2 m/s: 2.4 m of it was the walk.
    assert round(s["walking_excess_max"], 2) == 5.6
    assert round(s["still_max"], 2) == 0.5
    assert round(s["off_route"], 2) == 0.0


def test_a_tick_between_still_and_walking_counts_only_overall():
    logs, plane, route, positions = _walk([0, 3], [0.0, 0.4])
    s = walk_scores(logs, plane, route, positions)
    assert round(s["all_max"], 2) == 3.0
    assert (s["walking_max"], s["still_max"]) == (0.0, 0.0)


def test_ticks_without_a_replayed_position_are_skipped():
    logs, plane, route, positions = _walk([0, 1, 2], [1.0, 1.0, 1.0])
    del positions["t1"]
    s = walk_scores(logs, plane, route, positions)
    assert round(s["all_max"], 2) == 2.0


def test_the_table_has_one_row_per_setting_with_means():
    a = {key: 1.0 for key, _ in COMPARE_COLUMNS}
    b = {k: 3.0 for k in a}
    table = compare_table([("x=1", [a, b]), ("x=2", [b])])
    lines = table.splitlines()
    assert len(lines) == 3
    assert lines[1].startswith("x=1") and "2.00" in lines[1]
    assert lines[2].startswith("x=2") and "3.00" in lines[2]
