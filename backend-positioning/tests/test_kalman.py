import math

from app import kalman


def test_latlng_round_trip():
    lat0, lng0 = 6.2, -75.6
    lat, lng = 6.2005, -75.5995
    x, y = kalman.latlng_to_local(lat, lng, lat0, lng0)
    lat2, lng2 = kalman.local_to_latlng(x, y, lat0, lng0)
    assert math.isclose(lat, lat2, abs_tol=1e-9)
    assert math.isclose(lng, lng2, abs_tol=1e-9)


def test_origin_maps_to_zero():
    lat0, lng0 = 6.2, -75.6
    x, y = kalman.latlng_to_local(lat0, lng0, lat0, lng0)
    assert math.isclose(x, 0.0, abs_tol=1e-9)
    assert math.isclose(y, 0.0, abs_tol=1e-9)


def test_predict_moves_state_by_velocity_times_dt():
    ukf = kalman.make_filter(0.0, 0.0)
    ukf.x[2] = 1.0  # vx = 1 m/s
    ukf.x[3] = 0.5  # vy = 0.5 m/s
    kalman.predict(ukf, dt=2.0)
    assert math.isclose(ukf.x[0], 2.0, abs_tol=1e-6)
    assert math.isclose(ukf.x[1], 1.0, abs_tol=1e-6)


def test_gps_update_pulls_estimate_toward_measurement():
    ukf = kalman.make_filter(0.0, 0.0)
    kalman.gps_update(ukf, x=10.0, y=10.0, accuracy=5.0)
    # Starting at the origin with a GPS fix at (10,10) - the posterior must
    # move toward the measurement, not stay at the prior.
    assert ukf.x[0] > 0.0
    assert ukf.x[1] > 0.0
    assert ukf.x[0] < 10.0  # a blend, not a full jump (prior still has weight)


def test_visual_update_applied_above_threshold():
    ukf = kalman.make_filter(0.0, 0.0)
    applied = kalman.visual_update(
        ukf, x=5.0, y=5.0, score=kalman.MIN_MATCH_SCORE + 0.1
    )
    assert applied is True
    assert ukf.x[0] > 0.0


def test_visual_update_skipped_below_threshold():
    ukf = kalman.make_filter(0.0, 0.0)
    x_before = ukf.x.copy()
    applied = kalman.visual_update(
        ukf, x=5.0, y=5.0, score=kalman.MIN_MATCH_SCORE - 0.1
    )
    assert applied is False
    assert (ukf.x == x_before).all()


def test_correction_error_is_positive():
    ukf = kalman.make_filter(0.0, 0.0)
    assert kalman.correction_error_meters(ukf) > 0.0


def test_clamp_confidence_handles_negative_cosine_similarity():
    # Qdrant's cosine similarity can be negative - navigation_logs.confidence_score
    # has CHECK (BETWEEN 0 AND 1), so this must never leave the service unclamped.
    assert kalman.clamp_confidence(-0.4) == 0.0
    assert kalman.clamp_confidence(0.5) == 0.5
    assert kalman.clamp_confidence(1.4) == 1.0
