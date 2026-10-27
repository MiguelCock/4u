import os

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-key")
# Requests here carry no X-App-Version (see packages/app_versions.py).
os.environ.setdefault("APP_VERSION_GUARD", "off")
