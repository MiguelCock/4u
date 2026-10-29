import asyncio
import base64
import hashlib
import json
import logging
import mimetypes
import time
from typing import BinaryIO

from fastapi import Header, HTTPException
from supabase import AuthApiError, Client, create_client

logger = logging.getLogger(__name__)

# Supabase Auth error codes that mean the *caller's* token is bad (expired,
# malformed, revoked session, deleted user) - only these are a real 401.
_TOKEN_ERROR_CODES = {
    "bad_jwt",
    "no_authorization",
    "session_expired",
    "session_not_found",
    "user_not_found",
    "user_banned",
}


# A verified token is trusted again for this long without asking Supabase:
# every request used to pay a live Auth round trip, ~0.2-0.5 s on the
# navigation loop's every tick. The cost is that a token revoked by signing
# out elsewhere keeps working here for up to this long (an expired one
# never does: entries also end at the token's own expiry).
TOKEN_CACHE_SECONDS = 60.0
_TOKEN_CACHE_MAX = 1000


def _seconds_left(token: str) -> float | None:
    """Seconds until the JWT's own `exp`, read without verifying it - only
    ever used to shorten a cache entry for a token Supabase just accepted."""
    try:
        payload = token.split(".")[1]
        claims = json.loads(
            base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))
        )
        return float(claims["exp"]) - time.time()
    except IndexError, KeyError, TypeError, ValueError:
        return None


class AccountDeactivated(Exception):
    """The token is valid but its profile has `is_active = false`."""


def _deactivated(rows) -> bool:
    return isinstance(rows, list) and bool(rows) and rows[0].get("is_active") is False


class SupaBase:
    client: Client

    # Match db_schema/roles.sql's seeded rows. Shared by get_caller_id/
    # is_admin below so every service's admin check agrees on the same id.
    ADMIN_ROLE_ID = 2

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
        self,
        img: BinaryIO,
        filename: str,
        latitude: float,
        longitude: float,
        accuracy: float,
        heading: float | None = None,
    ):
        # Without an explicit content-type, storage3 defaults to text/plain,
        # which the real "Photo" bucket's MIME-type restriction rejects
        # (confirmed live) - same fix as upload_image already has.
        content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        self.client.storage.from_("Photo").upload(
            file=img.read(),
            path=filename,
            file_options={"content-type": content_type},
        )

        self.client.table("photos").insert(
            {
                "name": filename,
                "latitude": latitude,
                "longitude": longitude,
                "accuracy": accuracy,
                "heading": heading,
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

    def delete_images_by_url(self, bucket: str, urls: list[str]) -> None:
        # Takes public URLs (what every caller already has - e.g. an
        # `anchor_point_photos.image_url` column) rather than bare filenames,
        # so callers don't each need their own URL-parsing logic. Files were
        # always uploaded flat (see upload_image, no subdirectories), so the
        # last path segment is the storage-relative filename.
        filenames = [url.rsplit("/", 1)[-1] for url in urls if url]
        if filenames:
            self.client.storage.from_(bucket).remove(filenames)

    def get_photos(self):
        return self.client.table("photos").select("*").execute().data

    def get_photo(self, id: int):
        return self.client.table("photos").select("*").eq("id", id).execute().data

    def dele_photo(self, id: int):
        rows = self.client.table("photos").select("name").eq("id", id).execute().data

        self.client.table("photos").delete().eq("id", id).execute()

        if rows:
            self.client.storage.from_("Photo").remove([rows[0]["name"]])

    def get_user_id_from_token(self, access_token: str) -> str:
        # Verifies the token for real against Supabase Auth itself (not a
        # local signature check) - confirmed live that an invalid/expired
        # token raises supabase.AuthApiError, which this lets propagate so
        # callers can turn it into a 401. This is what lets a backend
        # service trust a caller-supplied id instead of taking it on faith.
        # A deactivated profile (profiles.is_active = false) is refused too,
        # with AccountDeactivated; it used to have no effect at all. No
        # profile row is allowed: the app's self-heal creates it.
        cache: dict[str, tuple[str, float, bool]] = self.__dict__.setdefault(
            "_token_cache", {}
        )
        key = hashlib.sha256(access_token.encode()).hexdigest()
        now = time.monotonic()
        hit = cache.get(key)
        if hit is not None and hit[1] > now:
            if hit[2]:
                raise AccountDeactivated(hit[0])
            return hit[0]
        user = self.client.auth.get_user(access_token).user
        deactivated = _deactivated(
            self.client.table("profiles")
            .select("is_active")
            .eq("id", user.id)
            .execute()
            .data
        )
        if len(cache) >= _TOKEN_CACHE_MAX:
            for stale in [k for k, (_, until) in cache.items() if until <= now]:
                del cache[stale]
            if len(cache) >= _TOKEN_CACHE_MAX:
                cache.clear()
        ttl = TOKEN_CACHE_SECONDS
        left = _seconds_left(access_token)
        if left is not None:
            ttl = min(ttl, left)
        if ttl > 0:
            cache[key] = (user.id, now + ttl, deactivated)
        if deactivated:
            raise AccountDeactivated(user.id)
        return user.id

    async def get_caller_id(
        self, authorization: str | None = Header(default=None)
    ) -> str:
        """FastAPI dependency: verifies the caller's Supabase Auth bearer
        token for real (via get_user_id_from_token above, not a local
        signature check) and returns the real, verified caller id - the
        reusable template introduced in #111 and rolled out to every
        service in #24, now shared here instead of copy-pasted per service.
        401s on anything missing, malformed, or rejected by Supabase
        (expired/invalid token).

        Bind it once per service as a plain module-level name so
        `Depends(get_caller_id)` and `app.dependency_overrides[get_caller_id]`
        in tests keep working:

            db = SupaBase(...)
            get_caller_id = db.get_caller_id
        """
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Missing bearer token")
        token = authorization.removeprefix("Bearer ").strip()
        if not token:
            raise HTTPException(status_code=401, detail="Missing bearer token")
        try:
            # Off the event loop: it's a blocking network call on a miss.
            return await asyncio.to_thread(self.get_user_id_from_token, token)
        except AccountDeactivated as e:
            raise HTTPException(status_code=403, detail="Account deactivated") from e
        except AuthApiError as e:
            if e.code in _TOKEN_ERROR_CODES:
                raise HTTPException(
                    status_code=401, detail="Invalid or expired token"
                ) from e
            # No token-specific code: Supabase rejected *this service's own*
            # credentials (e.g. Kong's "Invalid API key" for a wrong
            # SUPABASE_SERVICE_ROLE_KEY), not the caller's token. Reporting
            # that as a 401 made the app say "session expired" forever, and
            # signing in again could never fix it.
            logger.error(
                "Supabase rejected token verification (status=%s code=%s): %s",
                e.status,
                e.code,
                e.message,
            )
            raise HTTPException(
                status_code=503, detail="Authentication service unavailable"
            ) from e
        except Exception as e:
            logger.exception("Token verification failed unexpectedly")
            raise HTTPException(
                status_code=503, detail="Authentication service unavailable"
            ) from e

    def is_admin(self, caller_id: str) -> bool:
        """Looks up the caller's own role_id (db_schema/roles.sql: 1 = user,
        2 = admin) - the shared admin-gate check behind every admin-only
        endpoint across all services."""
        result = (
            self.client.table("profiles")
            .select("role_id,is_active")
            .eq("id", caller_id)
            .execute()
        )
        return (
            bool(result.data)
            and result.data[0]["role_id"] == self.ADMIN_ROLE_ID
            and result.data[0].get("is_active") is not False
        )
