import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from stationary_check import count


def _log(stationary, speed, guidance="walking"):
    return {
        "debug": {
            "gps_speed": speed,
            "guidance": guidance,
            "correction": {"stationary": stationary},
        }
    }


def test_a_stop_while_walking_is_a_false_stop():
    c = count([_log(True, 1.2), _log(False, 1.3)])
    assert (c.ticks, c.stationary, c.walking, c.false_stops) == (2, 1, 2, 1)


def test_fast_speed_counts_as_walking_even_while_orienting():
    c = count([_log(True, 0.9, guidance="orienting")])
    assert c.false_stops == 1


def test_still_and_not_told_is_a_missed_stop():
    c = count([_log(False, 0.1, guidance="orienting"), _log(True, 0.0, "orienting")])
    assert (c.missed_stops, c.false_stops, c.stationary) == (1, 0, 1)


def test_zero_speed_while_walking_and_missing_speed_are_counted():
    c = count([_log(False, 0.0), _log(False, None, guidance="orienting")])
    assert (c.zero_speed_walking, c.no_speed) == (1, 1)


def test_ticks_without_a_correction_are_skipped():
    assert count([{"debug": {"gps_speed": 1.0}}, {}]).ticks == 0
