"""In-memory per-session filter state - lost on process restart, doesn't
work across multiple replicas. Accepted: Phase 1 is a single container per
service, no horizontal scaling.

Each session gets its own asyncio.Lock. Callers (app/main.py) must acquire
it via get_lock() and hold it for the full request - including the
awaited HTTP call to backend-ai-training, not just the predict/update
math below - before calling correct(). Without that, two in-flight
requests for the same session_id (e.g. a client retry) can interleave
around that awaited call and corrupt the filter's covariance, since
filterpy's UnscentedKalmanFilter isn't safe for concurrent callers.
correct() itself assumes the lock is already held and does no locking of
its own.

Idle sessions are evicted opportunistically (checked on every call, not a
background task) since nothing here subscribes to navigation_sessions'
own status transitions - without this, every session ever started would
stay in memory forever.
"""

import asyncio
import time
from dataclasses import dataclass, field

from filterpy.kalman import UnscentedKalmanFilter

from . import kalman

# A gap this long since the session's last call re-initializes from the new
# GPS fix instead of predicting a constant-velocity extrapolation through a
# long silence (app backgrounded, poor connectivity) - a large unchecked dt
# would extrapolate far from reality before any update could pull it back.
MAX_DT_SECONDS = 30.0
# Sessions idle longer than this are dropped on the next sweep.
SESSION_TTL_SECONDS = 15 * 60.0


@dataclass
class CorrectionResult:
    corrected_lat: float
    corrected_long: float
    correction_error: float
    anchor_match_id: str | None
    confidence_score: float | None


@dataclass
class _SessionState:
    ukf: UnscentedKalmanFilter
    lat0: float
    lng0: float
    last_call: float
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class SessionStore:
    def __init__(self) -> None:
        self._sessions: dict[str, _SessionState] = {}

    def _evict_stale(self) -> None:
        now = time.monotonic()
        stale = [
            sid
            for sid, s in self._sessions.items()
            if now - s.last_call > SESSION_TTL_SECONDS
        ]
        for sid in stale:
            del self._sessions[sid]

    def _get_or_create(self, session_id: str, lat: float, lng: float) -> _SessionState:
        # No `await` anywhere in this method - asyncio coroutines only yield
        # at await points, so this check-then-create is atomic with respect
        # to other coroutines, no explicit lock needed here.
        self._evict_stale()
        state = self._sessions.get(session_id)
        if state is None:
            ukf = kalman.make_filter(0.0, 0.0)
            state = _SessionState(
                ukf=ukf, lat0=lat, lng0=lng, last_call=time.monotonic()
            )
            self._sessions[session_id] = state
        return state

    def get_lock(self, session_id: str, lat: float, lng: float) -> asyncio.Lock:
        """Ensures the session exists and returns its lock. Callers must
        acquire this *before* doing anything else for the session (including
        the visual-match HTTP call in app/main.py) and hold it through the
        call to correct() below."""
        return self._get_or_create(session_id, lat, lng).lock

    async def correct(
        self,
        session_id: str,
        lat: float,
        lng: float,
        accuracy: float,
        visual_lat: float | None,
        visual_lng: float | None,
        visual_score: float | None,
        visual_anchor_id: str | None,
    ) -> CorrectionResult:
        """Caller must already hold this session's lock (see get_lock)."""
        state = self._get_or_create(session_id, lat, lng)
        now = time.monotonic()
        dt = now - state.last_call
        if dt > MAX_DT_SECONDS:
            # Long silence since the last call - re-initialize from this
            # fix rather than extrapolating a stale constant-velocity
            # guess through the gap.
            x0, y0 = kalman.latlng_to_local(lat, lng, state.lat0, state.lng0)
            state.ukf = kalman.make_filter(x0, y0)
        else:
            kalman.predict(state.ukf, dt)
        state.last_call = now

        x, y = kalman.latlng_to_local(lat, lng, state.lat0, state.lng0)
        kalman.gps_update(state.ukf, x, y, accuracy)

        anchor_match_id: str | None = None
        confidence_score: float | None = None
        if (
            visual_lat is not None
            and visual_lng is not None
            and visual_score is not None
        ):
            vx, vy = kalman.latlng_to_local(
                visual_lat, visual_lng, state.lat0, state.lng0
            )
            applied = kalman.visual_update(state.ukf, vx, vy, visual_score)
            if applied:
                anchor_match_id = visual_anchor_id
                confidence_score = kalman.clamp_confidence(visual_score)

        corrected_lat, corrected_long = kalman.local_to_latlng(
            state.ukf.x[0], state.ukf.x[1], state.lat0, state.lng0
        )
        return CorrectionResult(
            corrected_lat=corrected_lat,
            corrected_long=corrected_long,
            correction_error=kalman.correction_error_meters(state.ukf),
            anchor_match_id=anchor_match_id,
            confidence_score=confidence_score,
        )
