from unittest.mock import MagicMock

import pytest
from fastapi import HTTPException
from supabase import AuthApiError

from packages.supabase import SupaBase


def _make_supabase() -> SupaBase:
    # Bypass __init__ (and its eager create_client URL validation) - these
    # tests only exercise get_caller_id/is_admin against self.client, same
    # pattern as test_supabase_auth.py.
    db = SupaBase.__new__(SupaBase)
    db.client = MagicMock()
    return db


@pytest.mark.asyncio
async def test_get_caller_id_rejects_missing_header():
    db = _make_supabase()
    with pytest.raises(HTTPException) as exc_info:
        await db.get_caller_id(None)
    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_get_caller_id_rejects_non_bearer_header():
    db = _make_supabase()
    with pytest.raises(HTTPException) as exc_info:
        await db.get_caller_id("Basic garbage")
    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_get_caller_id_rejects_blank_token():
    db = _make_supabase()
    with pytest.raises(HTTPException) as exc_info:
        await db.get_caller_id("Bearer    ")
    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_get_caller_id_rejects_invalid_token():
    db = _make_supabase()
    db.client.auth.get_user.side_effect = AuthApiError(
        "invalid JWT: token is expired", 403, "bad_jwt"
    )
    with pytest.raises(HTTPException) as exc_info:
        await db.get_caller_id("Bearer garbage")
    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_get_caller_id_reports_bad_service_key_as_503():
    # Kong's "Invalid API key" carries no auth error code - it's this
    # service's own credentials that are wrong, not the caller's token.
    db = _make_supabase()
    db.client.auth.get_user.side_effect = AuthApiError("Invalid API key", 401, None)
    with pytest.raises(HTTPException) as exc_info:
        await db.get_caller_id("Bearer a-valid-token")
    assert exc_info.value.status_code == 503


@pytest.mark.asyncio
async def test_get_caller_id_reports_network_failure_as_503():
    db = _make_supabase()
    db.client.auth.get_user.side_effect = ConnectionError("unreachable")
    with pytest.raises(HTTPException) as exc_info:
        await db.get_caller_id("Bearer a-valid-token")
    assert exc_info.value.status_code == 503


@pytest.mark.asyncio
async def test_get_caller_id_returns_verified_user_id():
    db = _make_supabase()
    db.client.auth.get_user.return_value.user.id = "a1b2c3"
    result = await db.get_caller_id("Bearer a-real-looking-token")
    assert result == "a1b2c3"
    db.client.auth.get_user.assert_called_once_with("a-real-looking-token")


def test_is_admin_true_for_admin_role():
    db = _make_supabase()
    db.client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = [
        {"role_id": 2}
    ]
    assert db.is_admin("admin1") is True


def test_is_admin_false_for_user_role():
    db = _make_supabase()
    db.client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = [
        {"role_id": 1}
    ]
    assert db.is_admin("u1") is False


def test_is_admin_false_when_profile_missing():
    db = _make_supabase()
    db.client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = []
    assert db.is_admin("ghost") is False


def _jwt(exp: float) -> str:
    import base64
    import json

    claims = base64.urlsafe_b64encode(json.dumps({"exp": exp}).encode()).decode()
    return f"header.{claims.rstrip('=')}.signature"


@pytest.mark.asyncio
async def test_get_caller_id_caches_a_verified_token():
    import time

    db = _make_supabase()
    db.client.auth.get_user.return_value.user.id = "a1b2c3"
    token = _jwt(time.time() + 3600)
    assert await db.get_caller_id(f"Bearer {token}") == "a1b2c3"
    assert await db.get_caller_id(f"Bearer {token}") == "a1b2c3"
    db.client.auth.get_user.assert_called_once_with(token)


@pytest.mark.asyncio
async def test_get_caller_id_cache_expires(monkeypatch):
    import time

    from packages import supabase as module

    db = _make_supabase()
    db.client.auth.get_user.return_value.user.id = "a1b2c3"
    token = _jwt(time.time() + 3600)
    clock = [1000.0]
    monkeypatch.setattr(module.time, "monotonic", lambda: clock[0])
    await db.get_caller_id(f"Bearer {token}")
    clock[0] += module.TOKEN_CACHE_SECONDS + 1
    await db.get_caller_id(f"Bearer {token}")
    assert db.client.auth.get_user.call_count == 2


@pytest.mark.asyncio
async def test_get_caller_id_never_caches_past_the_token_expiry():
    import time

    db = _make_supabase()
    db.client.auth.get_user.return_value.user.id = "a1b2c3"
    token = _jwt(time.time() - 5)
    await db.get_caller_id(f"Bearer {token}")
    await db.get_caller_id(f"Bearer {token}")
    assert db.client.auth.get_user.call_count == 2


@pytest.mark.asyncio
async def test_get_caller_id_does_not_cache_a_rejected_token():
    db = _make_supabase()
    db.client.auth.get_user.side_effect = AuthApiError("expired", 403, "bad_jwt")
    for _ in range(2):
        with pytest.raises(HTTPException):
            await db.get_caller_id("Bearer garbage")
    assert db.client.auth.get_user.call_count == 2
