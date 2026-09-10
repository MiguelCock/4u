import os

import pytest
from dotenv import load_dotenv
from qdrant_client.models import PointStruct

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
