import os

import pytest
from dotenv import load_dotenv
from qdrant_client.models import (
    FieldCondition,
    Filter,
    GeoPoint,
    GeoRadius,
    MatchValue,
    PointStruct,
)

from packages.qdrant import Qdrant

load_dotenv()

QDRANT_URL = os.environ.get("QDRANT_URL")
QDRANT_KEY = os.environ.get("QDRANT_KEY")

pytestmark = pytest.mark.skipif(
    not QDRANT_URL or not QDRANT_KEY,
    reason="QDRANT_URL/QDRANT_KEY not set - skipping live Qdrant connectivity test",
)


def test_qdrant_connects_and_round_trips():
    client = Qdrant(url=QDRANT_URL, key=QDRANT_KEY)

    assert client.health_check() is True

    collection = "ci-connectivity-check"
    client.ensure_collection(collection, vector_size=4)
    try:
        client.client.upsert(
            collection,
            points=[
                PointStruct(id=1, vector=[0.1, 0.2, 0.3, 0.4], payload={"ok": True})
            ],
        )
        result = client.client.query_points(
            collection, query=[0.1, 0.2, 0.3, 0.4], limit=1
        )
        assert len(result.points) == 1
        assert result.points[0].payload == {"ok": True}
    finally:
        client.client.delete_collection(collection)


def test_ensure_collection_indexed_fields_enables_filter_delete():
    # Regression test: filtering (including filter-based delete) on a
    # payload field 400s against a real Qdrant server unless that field has
    # an explicit index - a mocked test can't catch this, since mocks don't
    # enforce that constraint. This reproduces the exact failure
    # (backend-ai-training's DELETE /index_anchor hit it against a live
    # project) and proves indexed_fields fixes it.
    client = Qdrant(url=QDRANT_URL, key=QDRANT_KEY)

    collection = "ci-indexed-field-delete-check"
    client.ensure_collection(collection, vector_size=4, indexed_fields=["category"])
    try:
        client.client.upsert(
            collection,
            points=[
                PointStruct(
                    id=1,
                    vector=[0.1, 0.2, 0.3, 0.4],
                    payload={"category": "keep"},
                ),
                PointStruct(
                    id=2,
                    vector=[0.5, 0.6, 0.7, 0.8],
                    payload={"category": "delete-me"},
                ),
            ],
        )

        client.client.delete(
            collection,
            points_selector=Filter(
                must=[
                    FieldCondition(key="category", match=MatchValue(value="delete-me"))
                ]
            ),
        )

        remaining = client.client.query_points(
            collection, query=[0.1, 0.2, 0.3, 0.4], limit=10
        )
        remaining_ids = {point.id for point in remaining.points}
        assert remaining_ids == {1}
    finally:
        client.client.delete_collection(collection)


def test_ensure_collection_geo_indexed_fields_enables_geo_radius_search():
    # Same regression shape as the keyword-field test above, but for the
    # geo filter backend-ai-training's /search_similar now uses to scope a
    # visual-similarity search to nearby anchor points - a GeoRadius
    # condition 400s against a real Qdrant server unless the field has an
    # explicit GEO (not KEYWORD) index.
    client = Qdrant(url=QDRANT_URL, key=QDRANT_KEY)

    collection = "ci-geo-indexed-field-check"
    client.ensure_collection(collection, vector_size=4, geo_indexed_fields=["location"])
    try:
        client.client.upsert(
            collection,
            points=[
                PointStruct(
                    id=1,
                    vector=[0.1, 0.2, 0.3, 0.4],
                    payload={"location": {"lon": -75.58, "lat": 6.2442}},
                ),
                PointStruct(
                    id=2,
                    vector=[0.1, 0.2, 0.3, 0.4],
                    payload={"location": {"lon": -73.0, "lat": 4.6}},
                ),
            ],
        )

        nearby = client.client.query_points(
            collection,
            query=[0.1, 0.2, 0.3, 0.4],
            limit=10,
            query_filter=Filter(
                must=[
                    FieldCondition(
                        key="location",
                        geo_radius=GeoRadius(
                            center=GeoPoint(lon=-75.58, lat=6.2442),
                            radius=150.0,
                        ),
                    )
                ]
            ),
        )
        nearby_ids = {point.id for point in nearby.points}
        assert nearby_ids == {1}
    finally:
        client.client.delete_collection(collection)
