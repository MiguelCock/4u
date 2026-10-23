import asyncio

import pytest

from app import session_store as session_store_module
from app.matching import MatchConfig
from app.session_store import SessionStore


def _match(anchor, lat, lng, score, heading=None, photo="p"):
    return {
        "anchor_point_id": anchor,
        "photo_id": f"{photo}-{anchor}",
        "latitude": lat,
        "longitude": lng,
        "score": score,
        "heading": heading,
    }


async def _correct(store, sid, **kwargs):
    async with store.get_lock(sid, kwargs["lat"], kwargs["lng"]):
        return await store.correct(sid, **kwargs)


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
            candidates=[_match("anchor-1", 6.20005, -75.6, 0.95)],
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
            candidates=[_match("anchor-2", 6.20001, -75.6, 0.1)],  # low score
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
        )
        state = store._sessions["s4"]
        state.ukf.x[2] = 50.0  # implausible velocity, to prove it gets discarded
        state.last_call -= session_store_module.MAX_DT_SECONDS + 10

        result = await store.correct(
            "s4",
            lat=6.2001,
            lng=-75.6,
            accuracy=5.0,
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


# --- gating (the field-test fixes) ------------------------------------------

# 0.0001 deg of latitude is ~11.1 m here.
_M = 0.0001 / 11.1


@pytest.mark.asyncio
async def test_a_match_far_from_the_gps_fix_is_not_applied():
    # 60 m ahead - something the camera sees, not where the user is.
    result = await _correct(
        SessionStore(),
        "far",
        lat=6.2,
        lng=-75.6,
        accuracy=5.0,
        candidates=[_match("ahead", 6.2 + 60 * _M, -75.6, 0.97)],
    )
    assert result.anchor_match_id is None
    assert abs(result.corrected_lat - 6.2) < 2 * _M
    assert result.debug["candidates"][0]["verdict"] == "too_far"


@pytest.mark.asyncio
async def test_a_match_photographed_facing_another_way_is_not_applied():
    result = await _correct(
        SessionStore(),
        "heading",
        lat=6.2,
        lng=-75.6,
        accuracy=8.0,
        compass_heading=10.0,
        candidates=[_match("behind", 6.2 + 5 * _M, -75.6, 0.95, heading=190.0)],
    )
    assert result.anchor_match_id is None
    assert result.debug["candidates"][0]["verdict"] == "heading_mismatch"


@pytest.mark.asyncio
async def test_the_best_candidate_that_passes_every_gate_is_used():
    result = await _correct(
        SessionStore(),
        "fallback",
        lat=6.2,
        lng=-75.6,
        accuracy=8.0,
        compass_heading=0.0,
        candidates=[
            _match("far", 6.2 + 80 * _M, -75.6, 0.99, heading=0.0),
            _match("near", 6.2 + 4 * _M, -75.6, 0.9, heading=20.0),
            _match("near", 6.2 + 4 * _M, -75.6, 0.8, heading=20.0, photo="q"),
        ],
    )
    assert result.anchor_match_id == "near"
    verdicts = {c["anchor_id"]: c["verdict"] for c in result.debug["candidates"]}
    # One vote per anchor: the "near" anchor's two photos count once.
    assert verdicts == {"far": "too_far", "near": "applied"}


@pytest.mark.asyncio
async def test_a_far_match_pulls_less_than_a_close_one():
    async def pull(distance_m):
        result = await _correct(
            SessionStore(),
            f"pull-{distance_m}",
            lat=6.2,
            lng=-75.6,
            accuracy=10.0,
            candidates=[_match("a", 6.2 + distance_m * _M, -75.6, 0.95)],
        )
        return (result.corrected_lat - 6.2) / (distance_m * _M)

    far, close = await pull(18), await pull(3)
    assert far < close
    # The old fixed 3 m sigma pulled ~0.9 of the way at 10 m accuracy.
    assert far < 0.7


@pytest.mark.asyncio
async def test_an_implausible_jump_is_refused_by_the_mahalanobis_gate():
    store = SessionStore()
    config = MatchConfig(max_distance_m=200.0, accuracy_factor=100.0)
    # Settle the filter with very accurate GPS first.
    for _ in range(3):
        await _correct(store, "maha", lat=6.2, lng=-75.6, accuracy=1.0, config=config)
    result = await _correct(
        store,
        "maha",
        lat=6.2,
        lng=-75.6,
        accuracy=1.0,
        config=config,
        candidates=[_match("jump", 6.2 + 30 * _M, -75.6, 0.99)],
    )
    assert result.anchor_match_id is None
    assert result.debug["candidates"][0]["verdict"] == "mahalanobis"


@pytest.mark.asyncio
async def test_the_same_gps_fix_is_fused_only_once():
    store = SessionStore()
    first = await _correct(
        store, "dup", lat=6.2, lng=-75.6, accuracy=5.0, gps_time="t1"
    )
    again = await _correct(
        store, "dup", lat=6.2, lng=-75.6, accuracy=5.0, gps_time="t1"
    )
    new = await _correct(store, "dup", lat=6.2, lng=-75.6, accuracy=5.0, gps_time="t2")
    assert first.debug["gps_fused"] is True
    assert again.debug["gps_fused"] is False
    assert new.debug["gps_fused"] is True
    # Re-fusing would have kept shrinking the uncertainty.
    assert again.correction_error >= first.correction_error - 1e-6


@pytest.mark.asyncio
async def test_debug_reports_inputs_for_tuning():
    result = await _correct(
        SessionStore(),
        "debug",
        lat=6.2,
        lng=-75.6,
        accuracy=7.0,
        compass_heading=45.0,
        candidates=[_match("a", 6.2 + 3 * _M, -75.6, 0.9, heading=50.0)],
    )
    entry = result.debug["candidates"][0]
    assert entry["verdict"] == "applied"
    assert entry["heading_diff"] == 5.0
    assert entry["distance_m"] == pytest.approx(3.0, abs=0.2)
    assert "sigma_m" in entry and "mahalanobis2" in entry
    assert result.debug["gps_accuracy_m"] == 7.0
