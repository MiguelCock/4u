"""Pure UKF fusion logic - no FastAPI, no I/O, no session bookkeeping. Kept
separate from app/main.py so the math is testable in isolation (same
rationale as backend-ai-training/app/embedding.py).

State: [x, y, vx, vy, bx, by] in a local tangent-plane (meters), origin at
the session's first GPS fix. (bx, by) is the GPS fix's own slowly-varying
offset (see make_filter); the reported position is (x, y) - valid at campus scale, not for a session
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
_MIN_VAR = 1e-9


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


def _fx(state: np.ndarray, dt: float, bias_tau: float = 120.0) -> np.ndarray:
    x, y, vx, vy, bx, by = state
    decay = math.exp(-dt / bias_tau)
    return np.array([x + vx * dt, y + vy * dt, vx, vy, bx * decay, by * decay])


def _hx(state: np.ndarray) -> np.ndarray:
    """A visual match measures the position itself."""
    return state[:2]


def _hx_gps(state: np.ndarray) -> np.ndarray:
    """A GPS fix measures the position plus the GPS's own offset."""
    return state[:2] + state[4:6]


def make_filter(
    x0: float,
    y0: float,
    pos_sigma: float = 5.0,
    bias_sigma: float = 0.0,
    bias_tau: float = 120.0,
) -> UnscentedKalmanFilter:
    """A freshly-initialized filter seeded at (x0, y0) with zero velocity -
    the correct state for a session's first call, before any motion has
    been observed.

    [bias_sigma]/[bias_tau] model the GPS offset as a first-order
    Gauss-Markov process: typically [bias_sigma] meters, changing over
    about [bias_tau] seconds. A field test walking a known path found GPS
    off to one side by a steady 3-5 m per straight, not scattered around
    it; with every fix treated as independent, each new one pulled the
    estimate back onto that offset right after a photo match had fixed
    it. With the offset in the state, a match corrects it and the
    correction persists. 0 disables it (the filter before this change).

    Calls predict(dt=0) once before returning - confirmed live (filterpy
    doesn't document this): calling update() on a filter that has never
    had predict() called at least once corrects against uninitialized
    sigma points and silently produces a nonsensical (sometimes negative)
    posterior covariance, not an error. Every filter this returns is
    immediately safe to update() - callers never need to know about this.
    """
    # kappa=0: every sigma-point weight positive (the models are linear, so
    # any valid spread gives the exact Kalman result).
    points = MerweScaledSigmaPoints(n=6, alpha=1.0, beta=2.0, kappa=0.0)
    ukf = UnscentedKalmanFilter(dim_x=6, dim_z=2, dt=1.0, hx=_hx, fx=_fx, points=points)
    ukf.x = np.array([x0, y0, 0.0, 0.0, 0.0, 0.0])
    # Start as uncertain as the fix that seeds it: a 20 m fix used to start
    # at +-5 m, so the first visual match was barely trusted at all. Part
    # of that is the GPS offset, which a match can tell apart.
    # The floor keeps P positive-definite (Cholesky) when the offset is off.
    bias_var = max(bias_sigma**2, _MIN_VAR)
    ukf.P = np.diag([pos_sigma**2, pos_sigma**2, 4.0, 4.0, bias_var, bias_var])
    ukf.Q = np.zeros((6, 6))
    ukf.bias_sigma = bias_sigma
    ukf.bias_tau = bias_tau
    ukf.predict(dt=0.0, bias_tau=bias_tau)
    return ukf


def predict(ukf: UnscentedKalmanFilter, dt: float) -> None:
    dt = max(dt, 0.0)
    # Gauss-Markov: this growth keeps the offset's spread at bias_sigma.
    bias_var = 2 * ukf.bias_sigma**2 / ukf.bias_tau
    ukf.Q = (
        np.diag(
            [
                _PROCESS_VAR_POS,
                _PROCESS_VAR_POS,
                _PROCESS_VAR_VEL,
                _PROCESS_VAR_VEL,
                bias_var,
                bias_var,
            ]
        )
        * dt
    )
    ukf.predict(dt=dt, bias_tau=ukf.bias_tau)


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
    ukf.Q = np.zeros((6, 6))
    ukf.predict(dt=0.0, bias_tau=ukf.bias_tau)
    ukf.Q = q


def gps_update(ukf: UnscentedKalmanFilter, x: float, y: float, accuracy: float) -> None:
    _resync_sigma_points(ukf)
    sigma = max(accuracy, 1.0)
    ukf.update(np.array([x, y]), R=np.diag([sigma**2, sigma**2]), hx=_hx_gps)


def _hv(state: np.ndarray) -> np.ndarray:
    return state[2:4]


# 1-sigma of the "not moving" pseudo-measurement, m/s.
STATIONARY_SIGMA_MPS = 0.3


def stationary_update(
    ukf: UnscentedKalmanFilter, sigma: float = STATIONARY_SIGMA_MPS
) -> None:
    """Velocity ~ 0. The app's GPS stream has a 1 m distance filter, so no
    new fix since the last call means the user moved less than that. A
    field test skipped such repeated fixes instead: while the user stood
    orienting for ~12 s the velocity uncertainty (1 m/s) grew the position
    uncertainty to ~12 m, and the next photo match then pulled the
    position ~9 m in one tick, then GPS pulled it back."""
    _resync_sigma_points(ukf)
    ukf.update(np.zeros(2), R=np.diag([sigma**2, sigma**2]), hx=_hv)


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


def gps_bias(ukf: UnscentedKalmanFilter) -> tuple[float, float]:
    return float(ukf.x[4]), float(ukf.x[5])


def correction_error_meters(ukf: UnscentedKalmanFilter) -> float:
    return math.hypot(math.sqrt(ukf.P[0, 0]), math.sqrt(ukf.P[1, 1]))


def clamp_confidence(score: float) -> float:
    """Qdrant cosine similarity can be negative; navigation_logs.confidence_score
    has CHECK (BETWEEN 0 AND 1) - clamp before this ever leaves the service."""
    return max(0.0, min(1.0, score))
