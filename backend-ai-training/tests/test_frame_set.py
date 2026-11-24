import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import pytest
from build_frame_set import (
    Plane,
    checkpoint_taps,
    label_frames,
    route_corners,
    truth_at,
)

LAT, LNG = 6.2, -75.6
M = 1 / 111_320


def _anchors():
    # An L: 20 m north, then 20 m east.
    east = M / math.cos(math.radians(LAT))
    return {
        "a": {"id": "a", "latitude": LAT, "longitude": LNG},
        "b": {"id": "b", "latitude": LAT + 20 * M, "longitude": LNG},
        "c": {"id": "c", "latitude": LAT + 20 * M, "longitude": LNG + 20 * east},
    }


ROUTE = {"start_anchor_id": "a", "waypoint_anchor_ids": ["b"], "end_anchor_id": "c"}


def _log(i, t, events=(), frame=True):
    return {
        "id": f"l{i}",
        "timestamp": f"2026-11-13T18:00:{t:02d}+00:00",
        "raw_image_url": f"https://x/{i}.jpg" if frame else None,
        "gps_lat": LAT,
        "gps_long": LNG,
        "debug": {
            "photo_at": f"2026-11-13T18:00:{t:02d}+00:00",
            "events": [
                {
                    "type": "checkpoint",
                    "index": i,
                    "at": f"2026-11-13T18:00:{t:02d}+00:00",
                }
                for i in events
            ],
            "correction": {"compass": 10.0},
        },
    }


def test_the_corner_is_a_checkpoint():
    anchors = _anchors()
    plane = Plane(LAT, LNG)
    points = [plane.xy(anchors[k]["latitude"], anchors[k]["longitude"]) for k in "abc"]
    assert route_corners(points) == [0, 1, 2]


def test_frames_between_taps_get_the_steady_pace_position():
    logs = [
        _log(0, 0, events=[0]),
        _log(1, 10),
        _log(2, 20, events=[1]),
        _log(3, 40, events=[2]),
    ]
    frames = label_frames({"id": "s"}, logs, ROUTE, _anchors())
    assert [f["id"] for f in frames] == ["l0", "l1", "l2", "l3"]
    # Halfway in time between the start and the corner: 10 m north.
    assert (frames[1]["truth_lat"] - LAT) / M == pytest.approx(10, abs=0.2)
    assert frames[1]["heading"] == 10.0
    assert frames[1]["local_hour"] == pytest.approx(13.0)


def test_a_walk_with_one_tap_has_no_truth():
    logs = [_log(0, 0, events=[0]), _log(1, 10)]
    assert label_frames({"id": "s"}, logs, ROUTE, _anchors()) == []


def test_logs_without_a_frame_are_left_out():
    logs = [_log(0, 0, events=[0]), _log(1, 10, frame=False), _log(2, 20, events=[1])]
    assert [f["id"] for f in label_frames({"id": "s"}, logs, ROUTE, _anchors())] == [
        "l0",
        "l2",
    ]


def test_truth_is_none_outside_the_taps():
    taps = [(100.0, 0.0), (110.0, 10.0)]
    points = [(0.0, 0.0), (0.0, 20.0)]
    assert truth_at(99, taps, points) is None
    assert truth_at(105, taps, points) == pytest.approx((0.0, 5.0))
    assert checkpoint_taps([], points) == []


def test_a_frame_is_right_when_its_top_anchor_is_near_the_truth():
    import numpy as np
    from benchmark_models import score_frame

    xy = {"near": (0.0, 2.0), "far": (0.0, 30.0)}
    v = np.array([1.0, 0.0])
    pool = [("near", np.array([0.9, 0.1])), ("far", np.array([0.2, 0.9]))]
    r = score_frame({}, pool, v, xy, (0.0, 0.0))
    assert r == {"error_m": 2.0, "within_8m": True, "is_nearest": True}
    wrong = score_frame(
        {},
        [("far", np.array([1.0, 0.0])), ("near", np.array([0.0, 1.0]))],
        v,
        xy,
        (0.0, 0.0),
    )
    assert (wrong["within_8m"], wrong["is_nearest"]) == (False, False)
    assert score_frame({}, [], v, xy, (0.0, 0.0)) is None
