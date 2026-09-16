import mimetypes
from typing import BinaryIO

from supabase import Client, create_client


class SupaBase:
    client: Client

    def __init__(self, url: str, key: str):
        self.client = create_client(url, key)

    def health_check(self) -> bool:
        # `roles` is a small, always-seeded reference table (db_schema/roles.sql) -
        # a lightweight, RLS-safe way to prove the URL/key are valid and the
        # project is reachable, without touching real user data. The PostgREST
        # OpenAPI root (`/rest/v1/`) can't be used for this - newer Supabase
        # projects restrict that introspection endpoint to secret keys only.
        self.client.table("roles").select("id").limit(1).execute()
        return True

    def post_photos(
        self, img: BinaryIO, latitude: float, longitude: float, accuracy: float
    ):
        self.client.storage.from_("Photo").upload(file=img.read(), path=img.name)

        self.client.table("Photo").insert(
            {
                "name": img.name,
                "latitude": latitude,
                "longitude": longitude,
                "accuracy": accuracy,
            }
        ).execute()

    def upload_image(self, bucket: str, file: BinaryIO, filename: str) -> str:
        content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        self.client.storage.from_(bucket).upload(
            file=file.read(),
            path=filename,
            file_options={"content-type": content_type},
        )
        return self.client.storage.from_(bucket).get_public_url(filename)

    def get_photos(self):
        return self.client.table("Photo").select("*").execute().data

    def get_photo(self, id: int):
        return self.client.table("Photo").select("*").eq("id", id).execute().data

    def dele_photo(self, id: int):
        name = self.client.table("Photo").select("name").eq("id", id).execute().data

        self.client.table("Photo").delete().eq("id", id).execute()

        self.client.storage.from_("Photo").remove([name])

    def sing_up(self, email: str, password: str):
        self.client.auth.sign_up(
            {
                "email": email,
                "password": password,
            }
        )

    def log_in(self, email: str, password: str):
        self.client.auth.sign_in_with_password(
            {
                "email": email,
                "password": password,
            }
        )

    def is_logged_in(self, token) -> bool:
        return True
