import os

os.environ.setdefault("QDRANT_URL", "https://example.qdrant.io")
os.environ.setdefault("QDRANT_KEY", "test-key")
# Needed as of #24 - module import eagerly builds a SupaBase client to
# verify caller bearer tokens / admin role (see app/main.py).
os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-key")
