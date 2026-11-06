import os
from concurrent.futures import ThreadPoolExecutor

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


def test_many_threads_can_read_at_once():
    """Failed with ReadError on the library's default shared HTTP/2 connection."""
    db = SupaBase(os.environ["SUPABASE_URL"], os.environ["SUPABASE_PUBLISHABLE_KEY"])

    def read(_):
        return db.client.table("roles").select("*").limit(1).execute()

    with ThreadPoolExecutor(max_workers=30) as pool:
        results = list(pool.map(read, range(120)))
    assert len(results) == 120
