"""Which visual match, if any, may correct the position - pure, no I/O.

A field test showed the old rule (top-1 match above a score, used as "the
user is standing exactly on that anchor") pulled the position onto
whatever anchor the camera saw, up to 150 m away: the position jumped back
and forth, and near the end it snapped onto the destination. A match now
has to pass every gate below, and even then it only pulls as hard as its
distance from the GPS fix allows (see `visual_sigma`).

Every value can be overridden by an environment variable, so tuning needs
a container restart, not an app release. Read the per-tick `debug` the
service returns (stored in navigation_logs.debug) to tune them.
"""

import math
import os
from dataclasses import dataclass


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


@dataclass(frozen=True)
class MatchConfig:
    # Cosine similarity a candidate needs at all - on the scale of the
    # embedding model backend-ai-training runs. For its EigenPlaces model,
    # 95% of anchor-photo pairs more than 20 m apart score under 0.24 while
    # most same-spot and nearby ones score above it
    # (backend-ai-training/scripts/benchmark_models.py). With
    # EMBEDDING_MODEL=effnet set this to 0.75.
    min_score: float = 0.25
    # A matched anchor farther than max(this, factor x GPS accuracy) from
    # the GPS fix is not where the user is, it's something the camera sees.
    max_distance_m: float = 20.0
    accuracy_factor: float = 2.5
    # The matched photo was taken facing some direction; the phone must
    # face roughly the same way. Skipped when either heading is unknown.
    heading_gate_deg: float = 60.0
    # 1-sigma noise of an accepted match: base + per_m x distance to the
    # fix, so a far match pulls gently and a close one firmly.
    base_sigma_m: float = 3.0
    sigma_per_m: float = 0.3
    # Mahalanobis distance^2 limit (chi^2, 2 dof): 9.21 = 99%.
    mahalanobis_gate: float = 9.21
    # What backend-ai-training is asked for.
    search_radius_m: float = 60.0
    search_limit: int = 5
    # The GPS fix's own slowly-varying offset (see kalman.make_filter):
    # typical size, and how long it takes to change. 0 sigma disables it.
    # Replaying the first known-path walk (scripts/replay.py), distance
    # from the route fell from 3.64 m (off) to 2.70 (2.5 m) and 2.28 (4 m);
    # 6 m scored better still on that axis but leans harder on photo
    # matches, whose along-route error that walk couldn't measure.
    gps_bias_sigma_m: float = 4.0
    gps_bias_tau_s: float = 120.0
    # Scales the phone's reported accuracy into the GPS noise used.
    gps_sigma_factor: float = 1.0

    @classmethod
    def from_env(cls) -> MatchConfig:
        d = cls()
        return cls(
            min_score=_env_float("POSITIONING_MIN_MATCH_SCORE", d.min_score),
            max_distance_m=_env_float(
                "POSITIONING_MAX_MATCH_DISTANCE_M", d.max_distance_m
            ),
            accuracy_factor=_env_float(
                "POSITIONING_MATCH_ACCURACY_FACTOR", d.accuracy_factor
            ),
            heading_gate_deg=_env_float(
                "POSITIONING_HEADING_GATE_DEG", d.heading_gate_deg
            ),
            base_sigma_m=_env_float("POSITIONING_VISUAL_BASE_SIGMA_M", d.base_sigma_m),
            sigma_per_m=_env_float("POSITIONING_VISUAL_SIGMA_PER_M", d.sigma_per_m),
            mahalanobis_gate=_env_float(
                "POSITIONING_MAHALANOBIS_GATE", d.mahalanobis_gate
            ),
            search_radius_m=_env_float(
                "POSITIONING_SEARCH_RADIUS_M", d.search_radius_m
            ),
            search_limit=int(
                _env_float("POSITIONING_SEARCH_LIMIT", float(d.search_limit))
            ),
            gps_bias_sigma_m=_env_float(
                "POSITIONING_GPS_BIAS_SIGMA_M", d.gps_bias_sigma_m
            ),
            gps_bias_tau_s=max(
                _env_float("POSITIONING_GPS_BIAS_TAU_S", d.gps_bias_tau_s), 1.0
            ),
            gps_sigma_factor=_env_float(
                "POSITIONING_GPS_SIGMA_FACTOR", d.gps_sigma_factor
            ),
        )

    def as_dict(self) -> dict:
        return self.__dict__.copy()


def visual_sigma(config: MatchConfig, distance_m: float) -> float:
    return config.base_sigma_m + config.sigma_per_m * max(0.0, distance_m)


def heading_difference(a: float, b: float) -> float:
    """Smallest angle between two compass headings, 0-180 degrees."""
    diff = abs(a - b) % 360.0
    return 360.0 - diff if diff > 180.0 else diff


def best_per_anchor(matches: list[dict]) -> list[dict]:
    """One candidate per anchor point (its best-scoring photo), best first.
    Several photos of one place are one vote, not several."""
    best: dict[str, dict] = {}
    for match in matches:
        anchor = match.get("anchor_point_id")
        if anchor is None:
            continue
        if anchor not in best or match["score"] > best[anchor]["score"]:
            best[anchor] = match
    return sorted(best.values(), key=lambda m: m["score"], reverse=True)


def pre_filter_reason(
    config: MatchConfig,
    score: float,
    distance_m: float,
    gps_accuracy: float,
    photo_heading: float | None,
    compass_heading: float | None,
) -> str | None:
    """Why a candidate can't be used before touching the filter, or None.
    The Mahalanobis gate needs the filter state, so it's checked by the
    caller after these."""
    if score < config.min_score:
        return "low_score"
    if distance_m > max(config.max_distance_m, config.accuracy_factor * gps_accuracy):
        return "too_far"
    if (
        photo_heading is not None
        and compass_heading is not None
        and heading_difference(photo_heading, compass_heading) > config.heading_gate_deg
    ):
        return "heading_mismatch"
    return None


def finite(value: float | None) -> float | None:
    """JSON can't carry NaN/inf; diagnostics report them as null."""
    if value is None or not math.isfinite(value):
        return None
    return value
