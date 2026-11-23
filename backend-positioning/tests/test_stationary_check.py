import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from stationary_check import count


def _log(stationary, speed):
    return {
        "debug": {
            "gps_speed": speed,
            # Always "walking" in real logs, so it must not matter.
            "guidance": "walking",
            "correction": {"stationary": stationary},
        }
    }


def test_a_stop_while_moving_is_a_false_stop():
    c = count([_log(True, 1.2), _log(False, 1.3)])
    assert (c.ticks, c.stationary, c.walking, c.false_stops) == (2, 1, 2, 1)


def test_still_and_not_told_is_a_missed_stop_whatever_the_guidance():
    c = count([_log(False, 0.1), _log(True, 0.0)])
    assert (c.missed_stops, c.false_stops, c.stationary, c.walking) == (1, 0, 1, 0)


def test_between_still_and_walking_is_neither():
    c = count([_log(True, 0.4), _log(False, 0.4)])
    assert (c.false_stops, c.missed_stops) == (0, 0)


def test_missing_speed_is_counted():
    assert count([_log(False, None)]).no_speed == 1


def test_ticks_without_a_correction_are_skipped():
    assert count([{"debug": {"gps_speed": 1.0}}, {}]).ticks == 0
