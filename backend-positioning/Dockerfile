FROM python:3.12-slim

# Install uv.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Copy the shared `packages` library and this service into the container,
# preserving their sibling layout so `../packages` resolves in pyproject.toml.
COPY packages /packages
COPY backend-positioning /app

WORKDIR /app
RUN uv sync --frozen --no-cache

CMD ["/app/.venv/bin/fastapi", "run", "app/main.py", "--port", "80", "--host", "0.0.0.0"]
