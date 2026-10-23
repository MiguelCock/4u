import asyncio
import io
import logging
import os
import time
import uuid
from typing import Annotated

import httpx
from dotenv import load_dotenv
from fastapi import (
    BackgroundTasks,
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    UploadFile,
)
from packages.db_errors import install_db_error_handlers
from packages.supabase import SupaBase

from .matching import MatchConfig
from .models import CorrectPositionResponse
from .session_store import SessionStore

load_dotenv()

app = FastAPI()
install_db_error_handlers(app)

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

# Gates and noise for visual matches; POSITIONING_* environment variables
# override them (see app/matching.py), read once at startup.
_config = MatchConfig.from_env()

# Short per-attempt timeout + a couple of quick retries - a blip in the
# visual-matching service must not break navigation. backend-ai-training's
# model load does a real network download on its first call after any
# restart (fixed in this same change via its Dockerfile - see that diff),
# so a single bare timeout isn't enough of a safety net on its own.
_SEARCH_TIMEOUT_SECONDS = 2.0
_SEARCH_RETRIES = 2

_RETRYABLE_ERRORS = (httpx.HTTPError, httpx.TimeoutException)

# Admin test walks keep their camera frames (store_frame below), linked to
# each tick through navigation_logs.raw_image_url, so photo-matching models
# can be compared on real queries with a known true position. A public
# bucket like "anchor-points"; names carry a random UUID. Created on first
# use - the service-role key may.
FRAMES_BUCKET = "navigation-frames"
_frames_bucket_ready = False
_log = logging.getLogger(__name__)


def _ensure_frames_bucket() -> None:
    global _frames_bucket_ready
    if _frames_bucket_ready:
        return
    try:
        db.client.storage.get_bucket(FRAMES_BUCKET)
    except Exception:  # noqa: BLE001 - storage3 raises its own error types
        db.client.storage.create_bucket(FRAMES_BUCKET, options={"public": True})
    _frames_bucket_ready = True


def _store_frame(photo_bytes: bytes, filename: str) -> None:
    """Background task: best-effort, a failed upload only loses the frame."""
    try:
        _ensure_frames_bucket()
        db.upload_image(FRAMES_BUCKET, io.BytesIO(photo_bytes), filename)
    except Exception:  # noqa: BLE001
        _log.exception("storing navigation frame %s failed", filename)


@app.get("/")
async def root():
    return {"service": "backend-positioning", "status": "ok"}


async def _search_similar(
    photo_bytes: bytes, filename: str, latitude: float, longitude: float
) -> list[dict]:
    """Best-effort call to backend-ai-training's /search_similar, scoped to
    `_config.search_radius_m` around the caller's raw GPS fix. Returns up to
    `_config.search_limit` candidates (empty if the service is unreachable,
    slow, or finds nothing) - callers degrade to a GPS-only correction
    rather than failing the whole request over a visual-matching blip.
    Several candidates, not just the top one, so a far or wrong-direction
    top match doesn't hide a good second one."""
    async with httpx.AsyncClient(timeout=_SEARCH_TIMEOUT_SECONDS) as client:
        for attempt in range(_SEARCH_RETRIES + 1):
            try:
                response = await client.post(
                    f"{AI_TRAINING_URL}/search_similar",
                    files={"file": (filename, photo_bytes, "image/jpeg")},
                    data={
                        "limit": str(_config.search_limit),
                        "latitude": str(latitude),
                        "longitude": str(longitude),
                        "radius_meters": str(_config.search_radius_m),
                    },
                )
                response.raise_for_status()
                return response.json().get("matches", [])
            except _RETRYABLE_ERRORS:
                if attempt == _SEARCH_RETRIES:
                    return []
                await asyncio.sleep(0.2 * (attempt + 1))
    return []


@app.post("/correct_position")
async def correct_position(
    background: BackgroundTasks,
    session_id: Annotated[str, Form()],
    latitude: Annotated[float, Form()],
    longitude: Annotated[float, Form()],
    accuracy: Annotated[float, Form()],
    # The phone's compass heading (the direction the camera faces): a match
    # must have been photographed facing roughly the same way.
    heading: Annotated[float | None, Form()] = None,
    # The GPS fix's own timestamp, so the same fix sent again isn't fused
    # twice.
    gps_time: Annotated[str | None, Form()] = None,
    # Admin test walks only: keep this frame (see FRAMES_BUCKET).
    store_frame: Annotated[bool, Form()] = False,
    photo: UploadFile = File(...),
    caller_id: str = Depends(get_caller_id),
) -> CorrectPositionResponse:
    started = time.perf_counter()
    photo_bytes = await photo.read()
    frame_url = None
    if store_frame:
        if not db.is_admin(caller_id):
            raise HTTPException(status_code=403, detail="Admin only")
        # The URL is known before the upload, so the response doesn't wait
        # for it.
        name = f"frame-{session_id}-{uuid.uuid4().hex}.jpg"
        frame_url = db.client.storage.from_(FRAMES_BUCKET).get_public_url(name)
        background.add_task(_store_frame, photo_bytes, name)

    # Held across the visual-match HTTP call too, not just the predict/update
    # math - two in-flight requests for the same session_id (e.g. a client
    # retry) must not interleave around that awaited call. See
    # app/session_store.py's module docstring.
    lock = _store.get_lock(session_id, latitude, longitude)
    async with lock:
        search_started = time.perf_counter()
        candidates = await _search_similar(
            photo_bytes, photo.filename or "frame.jpg", latitude, longitude
        )
        search_ms = round(1000 * (time.perf_counter() - search_started))
        result = await _store.correct(
            session_id=session_id,
            lat=latitude,
            lng=longitude,
            accuracy=accuracy,
            candidates=candidates,
            compass_heading=heading,
            gps_time=gps_time,
            config=_config,
        )
    result.debug["search_ms"] = search_ms
    result.debug["total_ms"] = round(1000 * (time.perf_counter() - started))
    return _response(result, raw_image_url=frame_url)


def _response(result, raw_image_url: str | None = None) -> CorrectPositionResponse:
    return CorrectPositionResponse(
        corrected_lat=result.corrected_lat,
        corrected_long=result.corrected_long,
        correction_error=result.correction_error,
        anchor_match_id=result.anchor_match_id,
        confidence_score=result.confidence_score,
        raw_image_url=raw_image_url,
        debug=result.debug,
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
    starting anchor point before any navigation session exists. The same
    gates as /correct_position, through a throwaway filter that's dropped
    right after; a weak or missing match just returns the GPS fix."""
    photo_bytes = await photo.read()
    candidates = await _search_similar(
        photo_bytes, photo.filename or "frame.jpg", latitude, longitude
    )
    result = await SessionStore().correct(
        session_id="once",
        lat=latitude,
        lng=longitude,
        accuracy=accuracy,
        candidates=candidates,
        compass_heading=heading,
        config=_config,
    )
    return _response(result)
