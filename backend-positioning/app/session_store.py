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
import math
import time
from dataclasses import dataclass, field

from filterpy.kalman import UnscentedKalmanFilter

from . import kalman, matching

# A gap this long since the session's last call re-initializes from the new
# GPS fix instead of predicting a constant-velocity extrapolation through a
# long silence (app backgrounded, poor connectivity) - a large unchecked dt
# would extrapolate far from reality before any update could pull it back.
MAX_DT_SECONDS = 30.0
# Sessions idle longer than this are dropped on the next sweep.
SESSION_TTL_SECONDS = 15 * 60.0
# Live filters one caller may hold (see SessionStore.limit_owner).
MAX_SESSIONS_PER_OWNER = 5


@dataclass
class CorrectionResult:
    corrected_lat: float
    corrected_long: float
    correction_error: float
    anchor_match_id: str | None
    confidence_score: float | None
    # Why the position came out this way: candidates and their verdicts,
    # whether the GPS fix was fused, the applied match's noise and
    # innovation. Returned to the app and stored in navigation_logs.debug.
    debug: dict = field(default_factory=dict)


@dataclass
class _SessionState:
    ukf: UnscentedKalmanFilter
    lat0: float
    lng0: float
    last_call: float
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    # The last fused GPS fix's own timestamp: the app sends its latest fix
    # every tick, and while the user stands still that's the same fix again.
    last_gps_time: str | None = None
    started: bool = False


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

    def limit_owner(self, prefix: str, keep: int = MAX_SESSIONS_PER_OWNER) -> None:
        """Drops the least recently used filters whose key starts with
        [prefix] (one caller's) beyond [keep], so nobody can grow the store
        without bound by inventing session ids. Never touches a session
        whose lock is held (a request is using it)."""
        owned = sorted(
            (
                (state.last_call, sid)
                for sid, state in self._sessions.items()
                if sid.startswith(prefix) and not state.lock.locked()
            ),
            reverse=True,
        )
        for _, sid in owned[keep:]:
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

    @staticmethod
    def _new_filter(x0, y0, accuracy, config):
        return kalman.make_filter(
            x0,
            y0,
            pos_sigma=max(accuracy, 1.0),
            bias_sigma=config.gps_bias_sigma_m,
            bias_tau=config.gps_bias_tau_s,
        )

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
        candidates: list[dict] | None = None,
        compass_heading: float | None = None,
        gps_time: str | None = None,
        config: matching.MatchConfig | None = None,
    ) -> CorrectionResult:
        """Caller must already hold this session's lock (see get_lock).

        [candidates] are backend-ai-training matches (anchor_point_id,
        latitude, longitude, score, heading). At most one is applied: the
        best-scoring anchor that passes every gate in app/matching.py plus
        the Mahalanobis check against the current estimate."""
        config = config or matching.MatchConfig()
        state = self._get_or_create(session_id, lat, lng)
        now = time.monotonic()
        dt = now - state.last_call
        reinit = dt > MAX_DT_SECONDS
        stationary = False
        if state.last_gps_time is None and not state.started:
            # First call: seed the filter at this fix, as uncertain as it is.
            state.ukf = self._new_filter(0.0, 0.0, accuracy, config)
            state.started = True
            dt = 0.0
        elif reinit:
            # Long silence since the last call - re-initialize from this
            # fix rather than extrapolating a stale constant-velocity
            # guess through the gap.
            x0, y0 = kalman.latlng_to_local(lat, lng, state.lat0, state.lng0)
            state.ukf = self._new_filter(x0, y0, accuracy, config)
            state.last_gps_time = None
        else:
            if gps_time is not None and gps_time == state.last_gps_time:
                # No new fix since the last call: the user moved less than
                # the app's 1 m GPS distance filter over this interval, so
                # say so before projecting the velocity forward through it
                # (see kalman.stationary_update).
                kalman.stationary_update(state.ukf)
                stationary = True
            kalman.predict(state.ukf, dt)
        state.last_call = now

        x, y = kalman.latlng_to_local(lat, lng, state.lat0, state.lng0)
        # The same fix again is not a new position reading - fusing it every
        # tick made the filter over-trust it (it was used as "not moving"
        # above instead).
        gps_fused = gps_time is None or gps_time != state.last_gps_time
        if gps_fused:
            kalman.gps_update(state.ukf, x, y, accuracy * config.gps_sigma_factor)
            state.last_gps_time = gps_time

        verdicts: list[dict] = []
        applied: dict | None = None
        ranked = matching.best_per_anchor(candidates or [])
        for candidate in ranked:
            cx, cy = kalman.latlng_to_local(
                candidate["latitude"], candidate["longitude"], state.lat0, state.lng0
            )
            distance = float(math.hypot(cx - x, cy - y))
            photo_heading = candidate.get("heading")
            verdict = {
                "anchor_id": candidate["anchor_point_id"],
                "photo_id": candidate.get("photo_id"),
                "score": round(float(candidate["score"]), 4),
                "distance_m": round(distance, 1),
                "photo_heading": photo_heading,
            }
            if photo_heading is not None and compass_heading is not None:
                verdict["heading_diff"] = round(
                    matching.heading_difference(photo_heading, compass_heading), 1
                )
            if applied is not None:
                verdict["verdict"] = "not_needed"
                verdicts.append(verdict)
                continue
            reason = matching.pre_filter_reason(
                config,
                float(candidate["score"]),
                distance,
                accuracy,
                photo_heading,
                compass_heading,
            )
            if reason is None:
                sigma = matching.visual_sigma(config, distance)
                # Consistency is judged with the anchor's own precision; the
                # distance-scaled sigma only sets how hard it pulls (scaled,
                # the gate would let ever-farther matches through).
                innovation_m, d2 = kalman.innovation(
                    state.ukf, cx, cy, config.base_sigma_m
                )
                verdict["sigma_m"] = round(sigma, 2)
                verdict["innovation_m"] = round(innovation_m, 1)
                verdict["mahalanobis2"] = matching.finite(round(d2, 2))
                if not d2 <= config.mahalanobis_gate:
                    reason = "mahalanobis"
                else:
                    kalman.visual_update(
                        state.ukf,
                        cx,
                        cy,
                        float(candidate["score"]),
                        sigma=sigma,
                        min_score=config.min_score,
                    )
                    applied = candidate
            verdict["verdict"] = reason or "applied"
            verdicts.append(verdict)

        corrected_lat, corrected_long = kalman.local_to_latlng(
            state.ukf.x[0], state.ukf.x[1], state.lat0, state.lng0
        )
        error = kalman.correction_error_meters(state.ukf)
        return CorrectionResult(
            corrected_lat=corrected_lat,
            corrected_long=corrected_long,
            correction_error=error,
            anchor_match_id=applied["anchor_point_id"] if applied else None,
            confidence_score=(
                kalman.clamp_confidence(float(applied["score"])) if applied else None
            ),
            debug={
                "dt_s": round(dt, 2),
                "reinit": reinit,
                "gps_fused": gps_fused,
                "stationary": stationary,
                "gps_accuracy_m": accuracy,
                "compass": compass_heading,
                "candidates": verdicts,
                "velocity": [
                    round(float(state.ukf.x[2]), 2),
                    round(float(state.ukf.x[3]), 2),
                ],
                "correction_error_m": matching.finite(round(error, 2)),
                "gps_bias": [round(b, 2) for b in kalman.gps_bias(state.ukf)],
                # How far the best anchor stands out from the next one - a
                # candidate confidence signal (see docs/TUNING.md).
                "score_margin": round(ranked[0]["score"] - ranked[1]["score"], 4)
                if len(ranked) > 1
                else None,
            },
        )
