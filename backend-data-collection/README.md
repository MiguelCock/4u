Following [https://docs.astral.sh/uv/guides/integration/fastapi/#migrating-an-existing-fastapi-project](link) for guidelines starting project

uv run fastapi dev

docker build -t fastapi-app .

docker run -p 8000:80 fastapi-app

