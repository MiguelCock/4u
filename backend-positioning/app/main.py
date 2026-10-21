import asyncio
import os
from typing import Annotated

import httpx
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, UploadFile
from packages.supabase import SupaBase

from . import kalman
from .models import CorrectPositionResponse
from .session_store import SessionStore

load_dotenv()

app = FastAPI()

# Added in the app-integration follow-up to #24 - the app is this
# endpoint's first real end-user caller, so it needs the same per-request
# auth every other service has. Only used to verify caller bearer tokens
# (same shape of change #24 made to backend-ai-training) - this service
# still never queries Postgres for anything else.
db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)
get_caller_id = db.get_caller_id

# The other external dependency this service has - no Qdrant credentials
# of its own (see CLAUDE.md for why). Defaults to the Docker Compose
# service DNS name - the call to backend-ai-training stays on the internal
# network, no gateway hop needed for this service-to-service call.
AI_TRAINING_URL = os.environ.get("AI_TRAINING_URL", "http://ai-training:80")

_store = SessionStore()

# Short per-attempt timeout + a couple of quick retries - a blip in the
# visual-matching service must not break navigation. backend-ai-training's
# model load does a real network download on its first call after any
# restart (fixed in this same change via its Dockerfile - see that diff),
# so a single bare timeout isn't enough of a safety net on its own.
_SEARCH_TIMEOUT_SECONDS = 2.0
_SEARCH_RETRIES = 2

_RETRYABLE_ERRORS = (httpx.HTTPError, httpx.TimeoutException)


@app.get("/")
async def root():
    return {"service": "backend-positioning", "status": "ok"}


async def _search_similar(
    photo_bytes: bytes, filename: str, latitude: float, longitude: float
) -> dict | None:
    """Best-effort call to backend-ai-training's /search_similar. Returns
    the best (highest-score) match, or None if the service is unreachable,
    slow, or returns no matches - callers degrade to a GPS-only correction
    rather than failing the whole request over a visual-matching blip.

    Forwards the caller's raw (pre-correction) GPS fix so the search can be
    geo-scoped to nearby anchor points instead of the entire collection -
    this was sitting right here in `correct_position`'s own params and
    simply never got passed on before."""
    async with httpx.AsyncClient(timeout=_SEARCH_TIMEOUT_SECONDS) as client:
        for attempt in range(_SEARCH_RETRIES + 1):
            try:
                response = await client.post(
                    f"{AI_TRAINING_URL}/search_similar",
                    files={"file": (filename, photo_bytes, "image/jpeg")},
                    data={
                        "limit": "1",
                        "latitude": str(latitude),
                        "longitude": str(longitude),
                    },
                )
                response.raise_for_status()
                matches = response.json().get("matches", [])
                return matches[0] if matches else None
            except _RETRYABLE_ERRORS:
                if attempt == _SEARCH_RETRIES:
                    return None
                await asyncio.sleep(0.2 * (attempt + 1))
    return None


@app.post("/correct_position")
async def correct_position(
    session_id: Annotated[str, Form()],
    latitude: Annotated[float, Form()],
    longitude: Annotated[float, Form()],
    accuracy: Annotated[float, Form()],
    # Accepted but not fed into the filter in v1 - no IMU exists to pair it
    # with yet (see the IMU follow-up issue). Kept in the contract now so
    # that follow-up doesn't need a breaking API change.
    heading: Annotated[float | None, Form()] = None,
    photo: UploadFile = File(...),
    caller_id: str = Depends(get_caller_id),
) -> CorrectPositionResponse:
    photo_bytes = await photo.read()

    # Held across the visual-match HTTP call too, not just the predict/update
    # math - two in-flight requests for the same session_id (e.g. a client
    # retry) must not interleave around that awaited call. See
    # app/session_store.py's module docstring.
    lock = _store.get_lock(session_id, latitude, longitude)
    async with lock:
        match = await _search_similar(
            photo_bytes, photo.filename or "frame.jpg", latitude, longitude
        )

        result = await _store.correct(
            session_id=session_id,
            lat=latitude,
            lng=longitude,
            accuracy=accuracy,
            visual_lat=match["latitude"] if match else None,
            visual_lng=match["longitude"] if match else None,
            visual_score=match["score"] if match else None,
            visual_anchor_id=match["anchor_point_id"] if match else None,
        )

    return CorrectPositionResponse(
        corrected_lat=result.corrected_lat,
        corrected_long=result.corrected_long,
        correction_error=result.correction_error,
        anchor_match_id=result.anchor_match_id,
        confidence_score=result.confidence_score,
        raw_image_url=None,
    )


@app.post("/correct_position_once")
async def correct_position_once(
    latitude: Annotated[float, Form()],
    longitude: Annotated[float, Form()],
    accuracy: Annotated[float, Form()],
    heading: Annotated[float | None, Form()] = None,
    photo: UploadFile = File(...),
    caller_id: str = Depends(get_caller_id),
) -> CorrectPositionResponse:
    """A single, stateless GPS + visual correction - for picking a route's
    starting anchor point before any navigation session (and so any
    session_id/filter state) exists. Same math as /correct_position, via a
    throwaway filter seeded at the raw fix itself, so it shares the same
    MIN_MATCH_SCORE gate and confidence clamping; a weak or missing visual
    match just returns the GPS fix."""
    photo_bytes = await photo.read()
    match = await _search_similar(
        photo_bytes, photo.filename or "frame.jpg", latitude, longitude
    )

    ukf = kalman.make_filter(0.0, 0.0)
    kalman.gps_update(ukf, 0.0, 0.0, accuracy)

    anchor_match_id: str | None = None
    confidence_score: float | None = None
    if match is not None:
        vx, vy = kalman.latlng_to_local(
            match["latitude"], match["longitude"], latitude, longitude
        )
        if kalman.visual_update(ukf, vx, vy, match["score"]):
            anchor_match_id = match["anchor_point_id"]
            confidence_score = kalman.clamp_confidence(match["score"])

    corrected_lat, corrected_long = kalman.local_to_latlng(
        float(ukf.x[0]), float(ukf.x[1]), latitude, longitude
    )
    return CorrectPositionResponse(
        corrected_lat=corrected_lat,
        corrected_long=corrected_long,
        correction_error=kalman.correction_error_meters(ukf),
        anchor_match_id=anchor_match_id,
        confidence_score=confidence_score,
        raw_image_url=None,
    )
