"""Pure UKF fusion logic - no FastAPI, no I/O, no session bookkeeping. Kept
separate from app/main.py so the math is testable in isolation (same
rationale as backend-ai-training/app/embedding.py).

State: [x, y, vx, vy] in a local tangent-plane (meters), origin at the
session's first GPS fix - valid at campus scale, not for a session
spanning many kilometers (which doesn't happen in this app). Both fx/hx
below are linear, so a plain KalmanFilter would be mathematically
equivalent today - UKF is used anyway because it's forward-compatible
with a future IMU-based nonlinear update (bearing/angular-rate), not
because today's constant-velocity/direct-position math needs it.
"""

import math

import numpy as np
from filterpy.kalman import MerweScaledSigmaPoints, UnscentedKalmanFilter

R_EARTH_METERS = 6371000.0

# Default gate and noise for a visual match, kept for callers that don't
# pass their own (app/matching.py's MatchConfig holds the tunable values).
MIN_MATCH_SCORE = 0.75
VISUAL_SIGMA_METERS = 3.0

# Process noise *per second* (variance growth of a constant-velocity
# pedestrian model). Scaled by dt in predict(): it used to be added once
# per predict() call whatever the elapsed time, and again by every
# zero-dt resync, so the filter opened up far more than the time passed.
_PROCESS_VAR_POS = 0.5
_PROCESS_VAR_VEL = 0.3


def latlng_to_local(
    lat: float, lng: float, lat0: float, lng0: float
) -> tuple[float, float]:
    """Equirectangular approximation, origin at (lat0, lng0)."""
    x = math.radians(lng - lng0) * math.cos(math.radians(lat0)) * R_EARTH_METERS
    y = math.radians(lat - lat0) * R_EARTH_METERS
    return x, y


def local_to_latlng(
    x: float, y: float, lat0: float, lng0: float
) -> tuple[float, float]:
    lat = lat0 + math.degrees(y / R_EARTH_METERS)
    lng = lng0 + math.degrees(x / (R_EARTH_METERS * math.cos(math.radians(lat0))))
    return lat, lng


def _fx(state: np.ndarray, dt: float) -> np.ndarray:
    x, y, vx, vy = state
    return np.array([x + vx * dt, y + vy * dt, vx, vy])


def _hx(state: np.ndarray) -> np.ndarray:
    return state[:2]


def make_filter(x0: float, y0: float, pos_sigma: float = 5.0) -> UnscentedKalmanFilter:
    """A freshly-initialized filter seeded at (x0, y0) with zero velocity -
    the correct state for a session's first call, before any motion has
    been observed.

    Calls predict(dt=0) once before returning - confirmed live (filterpy
    doesn't document this): calling update() on a filter that has never
    had predict() called at least once corrects against uninitialized
    sigma points and silently produces a nonsensical (sometimes negative)
    posterior covariance, not an error. Every filter this returns is
    immediately safe to update() - callers never need to know about this.
    """
    points = MerweScaledSigmaPoints(n=4, alpha=1.0, beta=2.0, kappa=-1.0)
    ukf = UnscentedKalmanFilter(dim_x=4, dim_z=2, dt=1.0, hx=_hx, fx=_fx, points=points)
    ukf.x = np.array([x0, y0, 0.0, 0.0])
    # Start as uncertain as the fix that seeds it: a 20 m fix used to start
    # at +-5 m, so the first visual match was barely trusted at all.
    ukf.P = np.diag([pos_sigma**2, pos_sigma**2, 4.0, 4.0])
    ukf.Q = np.zeros((4, 4))
    ukf.predict(dt=0.0)
    return ukf


def predict(ukf: UnscentedKalmanFilter, dt: float) -> None:
    dt = max(dt, 0.0)
    ukf.Q = (
        np.diag(
            [_PROCESS_VAR_POS, _PROCESS_VAR_POS, _PROCESS_VAR_VEL, _PROCESS_VAR_VEL]
        )
        * dt
    )
    ukf.predict(dt=dt)


def _resync_sigma_points(ukf: UnscentedKalmanFilter) -> None:
    """A zero-dt predict that only regenerates sigma points from the
    filter's current x/P - doesn't move the state (dt=0). Confirmed live:
    calling update() twice in a row with no predict() between them reuses
    sigma points generated before the *first* update, which is
    inconsistent with the state/covariance the second update actually
    corrects against and can produce a nonsensical (sometimes negative)
    posterior covariance - reproduced directly with two tight-R updates
    back to back. gps_update/visual_update both call this before their own
    update() so they're safe to call in any order/combination without the
    caller needing to know about this. Q is zeroed for it: no time passes,
    so no process noise may be added."""
    q = ukf.Q
    ukf.Q = np.zeros((4, 4))
    ukf.predict(dt=0.0)
    ukf.Q = q


def gps_update(ukf: UnscentedKalmanFilter, x: float, y: float, accuracy: float) -> None:
    _resync_sigma_points(ukf)
    sigma = max(accuracy, 1.0)
    ukf.update(np.array([x, y]), R=np.diag([sigma**2, sigma**2]))


def visual_update(
    ukf: UnscentedKalmanFilter,
    x: float,
    y: float,
    score: float,
    sigma: float = VISUAL_SIGMA_METERS,
    min_score: float = MIN_MATCH_SCORE,
) -> bool:
    """Applies a visual-match correction with 1-sigma noise [sigma] if
    score clears [min_score]. Returns whether it was applied. The full gate
    list (distance, heading, Mahalanobis) is in app/matching.py and
    app/session_store.py."""
    if score < min_score:
        return False
    _resync_sigma_points(ukf)
    ukf.update(np.array([x, y]), R=np.diag([sigma**2, sigma**2]))
    return True


def innovation(
    ukf: UnscentedKalmanFilter, x: float, y: float, sigma: float
) -> tuple[float, float]:
    """How far a measurement at (x, y) with 1-sigma [sigma] is from the
    current estimate: (distance in meters, squared Mahalanobis distance).
    The measurement model is a direct position read-out, so this is exact
    from x/P without sigma points."""
    residual = np.array([x, y]) - ukf.x[:2]
    s = ukf.P[:2, :2] + np.diag([sigma**2, sigma**2])
    d2 = float(residual @ np.linalg.solve(s, residual))
    return float(np.hypot(*residual)), d2


def correction_error_meters(ukf: UnscentedKalmanFilter) -> float:
    return math.hypot(math.sqrt(ukf.P[0, 0]), math.sqrt(ukf.P[1, 1]))


def clamp_confidence(score: float) -> float:
    """Qdrant cosine similarity can be negative; navigation_logs.confidence_score
    has CHECK (BETWEEN 0 AND 1) - clamp before this ever leaves the service."""
    return max(0.0, min(1.0, score))
