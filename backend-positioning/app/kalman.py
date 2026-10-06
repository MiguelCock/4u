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

# Below this Qdrant cosine-similarity score, a visual match is treated as
# "no confident match" rather than deriving a noise magnitude from an
# uncalibrated number - a hard accept/reject gate is the honest choice here.
MIN_MATCH_SCORE = 0.75
# Fixed 1-sigma noise (meters) applied to an accepted visual match - not
# derived from the score, for the same reason.
VISUAL_SIGMA_METERS = 3.0

# Pedestrian-walking-speed-scale process noise - there's no real IMU-driven
# acceleration model yet, just a loose constant-velocity assumption.
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


def make_filter(x0: float, y0: float) -> UnscentedKalmanFilter:
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
    ukf.P = np.diag([25.0, 25.0, 4.0, 4.0])
    ukf.Q = np.diag(
        [_PROCESS_VAR_POS, _PROCESS_VAR_POS, _PROCESS_VAR_VEL, _PROCESS_VAR_VEL]
    )
    ukf.predict(dt=0.0)
    return ukf


def predict(ukf: UnscentedKalmanFilter, dt: float) -> None:
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
    caller needing to know about this."""
    ukf.predict(dt=0.0)


def gps_update(ukf: UnscentedKalmanFilter, x: float, y: float, accuracy: float) -> None:
    _resync_sigma_points(ukf)
    sigma = max(accuracy, 1.0)
    ukf.update(np.array([x, y]), R=np.diag([sigma**2, sigma**2]))


def visual_update(ukf: UnscentedKalmanFilter, x: float, y: float, score: float) -> bool:
    """Applies a visual-match correction if score clears MIN_MATCH_SCORE.
    Returns whether it was applied (callers use this to decide what to put
    in the response's anchor_match_id/confidence_score fields)."""
    if score < MIN_MATCH_SCORE:
        return False
    _resync_sigma_points(ukf)
    ukf.update(
        np.array([x, y]), R=np.diag([VISUAL_SIGMA_METERS**2, VISUAL_SIGMA_METERS**2])
    )
    return True


def correction_error_meters(ukf: UnscentedKalmanFilter) -> float:
    return math.hypot(math.sqrt(ukf.P[0, 0]), math.sqrt(ukf.P[1, 1]))


def clamp_confidence(score: float) -> float:
    """Qdrant cosine similarity can be negative; navigation_logs.confidence_score
    has CHECK (BETWEEN 0 AND 1) - clamp before this ever leaves the service."""
    return max(0.0, min(1.0, score))
