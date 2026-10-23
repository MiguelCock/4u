import asyncio
import math

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


@pytest.mark.asyncio
async def test_standing_still_keeps_a_photo_match_from_yanking_the_position(
    monkeypatch,
):
    # Field test: the user stood orienting ~12 s on one unchanged fix, then
    # a match 9 m away pulled the position ~8.6 m in one tick.
    clock = [1000.0]
    monkeypatch.setattr(session_store_module.time, "monotonic", lambda: clock[0])
    store = SessionStore()
    await _correct(store, "still", lat=6.2, lng=-75.6, accuracy=3.0, gps_time="t0")
    for _ in range(4):
        clock[0] += 3.5
        result = await _correct(
            store, "still", lat=6.2, lng=-75.6, accuracy=3.0, gps_time="t0"
        )
        assert result.debug["stationary"] is True
    clock[0] += 3.5
    result = await _correct(
        store,
        "still",
        lat=6.2,
        lng=-75.6,
        accuracy=3.0,
        gps_time="t0",
        candidates=[_match("a", 6.2 + 9 * _M, -75.6, 0.8)],
    )
    assert result.anchor_match_id == "a"
    pulled = (result.corrected_lat - 6.2) / _M
    # 8.8 m before (the field symptom), ~3 m now.
    assert pulled < 4.0


# --- GPS offset (bias) state ------------------------------------------------

# 1 m east in longitude degrees at latitude 6.2.
_E = _M / math.cos(math.radians(6.2))


async def _walk(monkeypatch, config, matches_every=3, wrong_at=None, ticks=30):
    """Walks north 1.2 m/s for [ticks] 3.5 s ticks with GPS a steady 5 m
    east of the truth (the field test's per-straight offset). Every
    [matches_every]-th tick a photo match on the true position, plus one
    6 m-wrong match at tick [wrong_at]. Returns per-tick east error (m)."""
    clock = [1000.0]
    monkeypatch.setattr(session_store_module.time, "monotonic", lambda: clock[0])
    store = SessionStore()
    errors = []
    for k in range(ticks):
        north = 1.2 * 3.5 * k
        truth_lat = 6.2 + north * _M
        candidates = []
        if matches_every and k % matches_every == matches_every - 1:
            candidates = [_match(f"a{k}", truth_lat, -75.6, 0.9)]
        if k == wrong_at:
            candidates = [_match("wrong", truth_lat, -75.6 + 6 * _E, 0.9)]
        result = await _correct(
            store,
            "bias",
            lat=truth_lat,
            lng=-75.6 + 5 * _E,
            accuracy=3.0,
            gps_time=f"t{k}",
            config=config,
            candidates=candidates,
        )
        errors.append((result.corrected_long + 75.6) / _E)
        clock[0] += 3.5
    return errors


@pytest.mark.asyncio
async def test_estimating_the_gps_offset_keeps_matches_correcting(monkeypatch):
    with_bias = await _walk(monkeypatch, MatchConfig())
    without = await _walk(monkeypatch, MatchConfig(gps_bias_sigma_m=0.0))
    late = slice(15, None)
    mean = lambda v: sum(abs(e) for e in v) / len(v)
    # GPS alone is 5 m off. Matches every ~10 s get the old filter only
    # part of the way; with the offset in the state the fix persists.
    assert mean(without[late]) > 2.5
    assert mean(with_bias[late]) < 0.6 * mean(without[late])
    # Between matches too, not only on the ticks that have one.
    between = [e for k, e in enumerate(with_bias) if k > 15 and k % 3 == 0]
    assert max(abs(e) for e in between) < 3.0


@pytest.mark.asyncio
async def test_without_matches_the_position_follows_gps(monkeypatch):
    errors = await _walk(monkeypatch, MatchConfig(), matches_every=0)
    assert all(abs(e - 5.0) < 1.0 for e in errors[3:])


@pytest.mark.asyncio
async def test_a_wrong_match_fades_instead_of_sticking(monkeypatch):
    clean = await _walk(monkeypatch, MatchConfig(), matches_every=0)
    hit = await _walk(monkeypatch, MatchConfig(), matches_every=0, wrong_at=5)
    effect = [h - c for h, c in zip(hit, clean)]
    assert abs(effect[5]) > 0.5
    # ~70 s later, well under the initial pull.
    assert abs(effect[25]) < 0.6 * abs(effect[5])
