from typing import BinaryIO
from pygments.token import String
from supabase import create_client, Client

class SupaBase():
    client: Client

    def __init__(self, url: String, key: String):
        self.client = create_client(url, key)

    def post_photos(self, img: BinaryIO):
        response = (self.client.storage
            .from_("Photo")
            .upload(
                file=img,
                path=img.name
            ))

    def get_photos(self):
        return self.client.table("Photo").select("*").execute().data

    def get_photo(self, id: int):
        return self.client.table("Photo").select("*").eq("id", id).execute().data

    def dele_photo(self, id: int):
        name = self.client.table("Photo").select("name").eq("id", id).execute().data

        resp1 = self.client.table("Photo").delete().eq("id", id).execute()

        resp2 = (self.client.storage
        .from_("Photo")
        .remove([name]))

    def sing_up(self, email: str, password: str):
        response = self.client.auth.sign_up({
            "email": email,
            "password": password,
        })

    def log_in(self, email: str, password: str):
        response = self.client.auth.sign_in_with_password({
            "email": email,
            "password": password,
        })
    
    def is_logged_in(self, token) -> bool:
        response = ""

        return True
