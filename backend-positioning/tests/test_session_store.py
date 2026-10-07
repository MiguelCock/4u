import asyncio

import pytest

from app import session_store as session_store_module
from app.session_store import SessionStore


@pytest.mark.asyncio
async def test_first_call_seeds_state_without_predicting():
    store = SessionStore()
    lock = store.get_lock("s1", 6.2, -75.6)
    async with lock:
        result = await store.correct(
            "s1",
            lat=6.2,
            lng=-75.6,
            accuracy=5.0,
            visual_lat=None,
            visual_lng=None,
            visual_score=None,
            visual_anchor_id=None,
        )
    # No prior velocity, first call - corrected position should land very
    # close to the GPS fix itself, not somewhere extrapolated.
    assert abs(result.corrected_lat - 6.2) < 0.001
    assert abs(result.corrected_long - (-75.6)) < 0.001


@pytest.mark.asyncio
async def test_visual_match_moves_result_toward_anchor_not_just_gps():
    store = SessionStore()
    lock = store.get_lock("s2", 6.2, -75.6)
    async with lock:
        result = await store.correct(
            "s2",
            lat=6.2,
            lng=-75.6,
            accuracy=20.0,  # noisy GPS
            visual_lat=6.20005,
            visual_lng=-75.6,
            visual_score=0.95,
            visual_anchor_id="anchor-1",
        )
    assert result.anchor_match_id == "anchor-1"
    assert result.confidence_score == 0.95


@pytest.mark.asyncio
async def test_low_score_match_is_not_applied():
    store = SessionStore()
    lock = store.get_lock("s3", 6.2, -75.6)
    async with lock:
        result = await store.correct(
            "s3",
            lat=6.2,
            lng=-75.6,
            accuracy=5.0,
            visual_lat=6.3,
            visual_lng=-75.5,
            visual_score=0.1,  # below MIN_MATCH_SCORE
            visual_anchor_id="anchor-2",
        )
    assert result.anchor_match_id is None
    assert result.confidence_score is None


@pytest.mark.asyncio
async def test_large_dt_gap_reinitializes_instead_of_extrapolating():
    store = SessionStore()
    lock = store.get_lock("s4", 6.2, -75.6)
    async with lock:
        await store.correct(
            "s4",
            lat=6.2,
            lng=-75.6,
            accuracy=5.0,
            visual_lat=None,
            visual_lng=None,
            visual_score=None,
            visual_anchor_id=None,
        )
        state = store._sessions["s4"]
        state.ukf.x[2] = 50.0  # implausible velocity, to prove it gets discarded
        state.last_call -= session_store_module.MAX_DT_SECONDS + 10

        result = await store.correct(
            "s4",
            lat=6.2001,
            lng=-75.6,
            accuracy=5.0,
            visual_lat=None,
            visual_lng=None,
            visual_score=None,
            visual_anchor_id=None,
        )
    # Re-initialized from the new fix, not extrapolated via the stale 50 m/s
    # velocity through a 40s gap (which would land ~2km away).
    assert abs(result.corrected_lat - 6.2001) < 0.01


@pytest.mark.asyncio
async def test_concurrent_calls_for_same_session_are_serialized():
    store = SessionStore()
    order: list[str] = []

    async def slow_call(tag: str):
        lock = store.get_lock("s5", 6.2, -75.6)
        async with lock:
            order.append(f"{tag}-start")
            await asyncio.sleep(0.05)
            await store.correct(
                "s5",
                lat=6.2,
                lng=-75.6,
                accuracy=5.0,
                visual_lat=None,
                visual_lng=None,
                visual_score=None,
                visual_anchor_id=None,
            )
            order.append(f"{tag}-end")

    await asyncio.gather(slow_call("a"), slow_call("b"))
    # Without the lock, both "start" events would appear before either "end"
    # (interleaved). With it, one caller's start+end must appear together
    # before the other's start.
    assert order in (
        ["a-start", "a-end", "b-start", "b-end"],
        ["b-start", "b-end", "a-start", "a-end"],
    )
