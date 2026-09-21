from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PayloadSchemaType, VectorParams


class Qdrant:
    client: QdrantClient

    def __init__(self, url: str, key: str):
        self.client = QdrantClient(url=url, api_key=key)

    def health_check(self) -> bool:
        self.client.get_collections()
        return True

    def ensure_collection(
        self,
        name: str,
        vector_size: int,
        distance: str = "Cosine",
        indexed_fields: list[str] | None = None,
    ) -> None:
        if not self.client.collection_exists(name):
            self.client.create_collection(
                collection_name=name,
                vectors_config=VectorParams(
                    size=vector_size, distance=Distance(distance)
                ),
            )

        # Filtering (including filter-based delete) on a payload field
        # requires an explicit index on that field - Qdrant rejects the
        # query otherwise. Called unconditionally (not just on first
        # creation) so this also repairs a collection that already existed
        # before a field started being filtered on. create_payload_index is
        # idempotent - safe to call again for a field that's already indexed.
        for field in indexed_fields or []:
            self.client.create_payload_index(
                name, field_name=field, field_schema=PayloadSchemaType.KEYWORD
            )
