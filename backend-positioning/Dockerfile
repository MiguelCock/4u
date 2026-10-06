FROM python:3.12-slim

# Install uv.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# No sibling `packages` dependency - this service doesn't touch Supabase or
# Qdrant directly (see CLAUDE.md), so there's nothing in that shared library
# for it to use.
COPY backend-positioning /app

WORKDIR /app
RUN uv sync --frozen --no-cache

CMD ["/app/.venv/bin/fastapi", "run", "app/main.py", "--port", "80", "--host", "0.0.0.0"]
