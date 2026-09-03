from qdrant_client import QdrantClient
from pygments.token import String

class SupaBase():
    client: QdrantClient

    def __init__(self, url: String, key: String):
        self.client = QdrantClient(
            url=url,
            api_key=key
        )

    def save_verctor(self, vector):
        pass

