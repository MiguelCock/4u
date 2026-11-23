import pytest

from loadtool.round import (
    by_campus_version,
    by_phone,
    read_sus,
    render_round,
    sus_score,
)
from loadtool.trip import Problem, summarize
from tests.test_trip import session, tick, walk


def _trip(device=None, *, arrive=True, problems=(), campus="UPB", **debug):
    logs = [
        {**log, "gps_accuracy": 4.0, "debug": {**log["debug"], **debug}}
        for log in walk(arrive=arrive)
    ]
    summary = summarize(session(device=device, end=60), logs)
    summary.campus = campus
    summary.problems += [Problem(10, kind, "") for kind in problems]
    return summary


PIXEL = {
    "manufacturer": "Google",
    "model": "Pixel 7",
    "os_version": "15",
    "app_version": "0.6.1",
}
OLD = {
    "manufacturer": "Motorola",
    "model": "e7",
    "os_version": "10",
    "app_version": "0.6.0",
}


def test_summarize_reads_the_sensors_gps_and_capture_time():
    s = _trip(PIXEL, gyroscope=True, pressure_hpa=850.1)
    assert (s.has_gyroscope, s.has_barometer) == (True, True)
    assert (s.gps_accuracy_m, s.capture_s, s.os_version) == (4.0, 0.4, "15")
    assert s.arrival_s == 60


def test_a_missing_sensor_is_no_and_an_unlogged_one_is_none():
    s = _trip(OLD, gyroscope=False, pressure_hpa=None)
    assert (s.has_gyroscope, s.has_barometer) == (False, False)
    plain = summarize(session(), [tick(0)])
    assert (plain.has_gyroscope, plain.has_barometer) == (None, None)


def test_trips_group_by_campus_and_version():
    trips = [
        _trip(PIXEL),
        _trip(PIXEL, arrive=False, problems=["stuck", "spinning"]),
        _trip(OLD, campus="EAFIT"),
    ]
    rows = {(r["campus"], r["version"]): r for r in by_campus_version(trips)}
    upb = rows[("UPB", "0.6.1")]
    assert (upb["trips"], upb["arrived"], upb["lost"], upb["lost_events"]) == (
        2,
        1,
        1,
        2,
    )
    assert upb["arrival_s"] == 60
    assert rows[("EAFIT", "0.6.0")]["trips"] == 1


def test_the_device_matrix_has_one_row_per_phone():
    trips = [
        _trip(PIXEL, gyroscope=True),
        _trip(PIXEL, gyroscope=False),
        _trip(OLD, pressure_hpa=None),
    ]
    rows = {r["phone"]: r for r in by_phone(trips)}
    pixel = rows["Google Pixel 7, Android 15"]
    assert (pixel["trips"], pixel["gyroscope"], pixel["barometer"]) == (
        2,
        "some trips",
        "not logged",
    )
    assert rows["Motorola e7, Android 10"]["barometer"] == "no"
    report = render_round(trips, [70.0, 80.0])
    assert "Motorola e7, Android 10" in report
    assert "Mean 75.0, median 75.0, n = 2" in report


def test_sus_score_uses_the_standard_formula():
    assert sus_score([5, 1] * 5) == 100
    assert sus_score([1, 5] * 5) == 0
    assert sus_score([3] * 10) == 50
    with pytest.raises(ValueError):
        sus_score([3] * 9)


def test_sus_answers_come_from_a_csv(tmp_path):
    path = tmp_path / "answers.csv"
    path.write_text(
        "code,q1,q2,q3,q4,q5,q6,q7,q8,q9,q10\nP1,5,1,5,1,5,1,5,1,5,1\nP2,3,3,3,3,3,3,3,3,3,3\n"
    )
    assert read_sus(str(path)) == [100.0, 50.0]
