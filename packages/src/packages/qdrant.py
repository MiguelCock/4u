from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams


class Qdrant:
    client: QdrantClient

    def __init__(self, url: str, key: str):
        self.client = QdrantClient(url=url, api_key=key)

    def health_check(self) -> bool:
        self.client.get_collections()
        return True

    def ensure_collection(
        self, name: str, vector_size: int, distance: str = "Cosine"
    ) -> None:
        if not self.client.collection_exists(name):
            self.client.create_collection(
                collection_name=name,
                vectors_config=VectorParams(
                    size=vector_size, distance=Distance(distance)
                ),
            )
