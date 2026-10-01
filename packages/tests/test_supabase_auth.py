from unittest.mock import MagicMock

import pytest
from supabase import AuthApiError

from packages.supabase import SupaBase


def _make_supabase() -> SupaBase:
    # Bypass __init__ (and its eager create_client URL validation) - these
    # tests only exercise how get_user_id_from_token calls self.client.
    db = SupaBase.__new__(SupaBase)
    db.client = MagicMock()
    return db


def test_get_user_id_from_token_returns_the_verified_user_id():
    db = _make_supabase()
    db.client.auth.get_user.return_value.user.id = "a1b2c3"

    result = db.get_user_id_from_token("a-real-looking-token")

    assert result == "a1b2c3"
    db.client.auth.get_user.assert_called_once_with("a-real-looking-token")


def test_get_user_id_from_token_raises_on_invalid_token():
    # Confirmed live against the real Supabase project: an invalid/expired
    # token makes supabase_auth's get_user() raise AuthApiError rather than
    # return None - this test pins that behavior against a mock so a future
    # supabase-auth upgrade changing it would be caught here, not in prod.
    db = _make_supabase()
    db.client.auth.get_user.side_effect = AuthApiError(
        "invalid JWT: unable to parse or verify signature", 401, "bad_jwt"
    )

    with pytest.raises(AuthApiError):
        db.get_user_id_from_token("garbage-not-a-real-token")
