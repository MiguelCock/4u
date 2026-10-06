import os

# Needed as of the app-integration follow-up to #24 - module import
# eagerly builds a SupaBase client to verify caller bearer tokens (see
# app/main.py).
os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-key")
