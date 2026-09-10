import os

import pytest
from dotenv import load_dotenv

from packages.supabase import SupaBase

load_dotenv()

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_PUBLISHABLE_KEY = os.environ.get("SUPABASE_PUBLISHABLE_KEY")

pytestmark = pytest.mark.skipif(
    not SUPABASE_URL or not SUPABASE_PUBLISHABLE_KEY,
    reason="SUPABASE_URL/SUPABASE_PUBLISHABLE_KEY not set - skipping live Supabase connectivity test",
)


def test_supabase_connects():
    client = SupaBase(url=SUPABASE_URL, key=SUPABASE_PUBLISHABLE_KEY)

    assert client.health_check() is True
