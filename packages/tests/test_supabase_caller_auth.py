from unittest.mock import MagicMock

import pytest
from fastapi import HTTPException

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
    db.client.auth.get_user.side_effect = Exception("bad token")
    with pytest.raises(HTTPException) as exc_info:
        await db.get_caller_id("Bearer garbage")
    assert exc_info.value.status_code == 401


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
