FROM python:3.14-slim

# Install uv.
COPY --from=ghcr.io/astral-sh/uv:0.12.3 /uv /uvx /bin/

# Copy the shared `packages` library and this service into the container,
# preserving their sibling layout so `../packages` resolves in pyproject.toml.
COPY packages /packages
COPY backend-ai-training /app

# Install the application dependencies.
WORKDIR /app
RUN uv sync --frozen --no-cache

# Bakes the pretrained weights into this image layer - EigenPlaces (~90MB,
# the default model, checksum-verified) and the ~20MB EfficientNet-B0 kept
# for EMBEDDING_MODEL=effnet
# at build time. Without this, _get_model() (app/embedding.py) downloads
# them from download.pytorch.org on literally the first real request after
# any container start/restart - confirmed live this can blow through a
# calling service's short timeout (see backend-positioning, the first
# real caller of /search_similar) and would corrupt any latency benchmark
# that happens to land on a cold container.
RUN .venv/bin/python -c "from torchvision.models import efficientnet_b0, EfficientNet_B0_Weights; efficientnet_b0(weights=EfficientNet_B0_Weights.DEFAULT)" \
 && .venv/bin/python -c "from app import embedding; embedding._eigenplaces_weights()"

# Run the application.
CMD ["/app/.venv/bin/fastapi", "run", "app/main.py", "--port", "80", "--host", "0.0.0.0"]
