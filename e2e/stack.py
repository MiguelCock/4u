"""Talking to the system under test as the app does: through the gateway, signed
in, with the app's version header. Settings come from scripts/e2e.sh, and point
at a local stack only. Nothing here can reach production by default."""

import io
import json
import os
import random
import uuid
from pathlib import Path

import httpx
from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parent.parent
VERSIONS = json.loads(
    (REPO / "packages" / "src" / "packages" / "app_versions.json").read_text()
)
LATEST = VERSIONS["latest"]
MIN_SUPPORTED = VERSIONS["min_supported"]

GATEWAY = os.environ.get("E2E_GATEWAY_URL", "http://127.0.0.1:18000").rstrip("/")
SUPABASE = os.environ.get("E2E_SUPABASE_URL", "http://127.0.0.1:54321").rstrip("/")
PUBLISHABLE_KEY = os.environ.get("E2E_PUBLISHABLE_KEY", "")
SERVICE_ROLE_KEY = os.environ.get("E2E_SERVICE_ROLE_KEY", "")

# Somewhere on EAFIT's campus; the tests' data never mixes with a real map,
# since the stack starts from an empty database.
CAMPUS = (6.2005, -75.5785)
METERS_PER_DEGREE = 111_320


def older_than_supported() -> str:
    """A version just below min_supported, which must be refused with 426."""
    major, minor, patch = (int(part) for part in MIN_SUPPORTED.split("."))
    if patch:
        return f"{major}.{minor}.{patch - 1}"
    return f"{major}.{minor - 1}.99"


def unique(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:8]}"


class Account:
    """One signed-in person, calling the gateway like the app."""

    def __init__(self, email: str, password: str, user_id: str, token: str):
        self.email = email
        self.password = password
        self.id = user_id
        self.token = token

    def client(self, version: str | None = LATEST) -> httpx.Client:
        headers = {"Authorization": f"Bearer {self.token}"}
        if version is not None:
            headers["X-App-Version"] = version
        return httpx.Client(base_url=GATEWAY, headers=headers, timeout=60)


def sign_up(role: str = "user") -> Account:
    """Signs up through Supabase Auth and creates the profile, as the app's
    sign-up screen does. Admins are then promoted directly in the database, as
    the README bootstraps the first admin."""
    email = f"{unique('e2e')}@example.com"
    password = unique("pw") + "Aa1!"
    response = httpx.post(
        f"{SUPABASE}/auth/v1/signup",
        json={"email": email, "password": password},
        headers={"apikey": PUBLISHABLE_KEY},
        timeout=30,
    )
    response.raise_for_status()
    body = response.json()
    account = Account(email, password, body["user"]["id"], body["access_token"])
    with account.client() as api:
        api.post("/user/profiles", json={"full_name": email}).raise_for_status()
    if role == "admin":
        promote(account.id)
    return account


def promote(user_id: str) -> None:
    httpx.patch(
        f"{SUPABASE}/rest/v1/profiles",
        params={"id": f"eq.{user_id}"},
        json={"role_id": 2},
        headers={
            "apikey": SERVICE_ROLE_KEY,
            "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
        },
        timeout=30,
    ).raise_for_status()


def offset(meters_north: float, meters_east: float = 0.0) -> tuple[float, float]:
    """A position this far from the campus point."""
    return (
        CAMPUS[0] + meters_north / METERS_PER_DEGREE,
        CAMPUS[1] + meters_east / METERS_PER_DEGREE,
    )


# Different photos in every run, so a run doesn't find an earlier run's points
# in photo search when the stack wasn't reset (running pytest directly).
RUN_SEED = random.SystemRandom().randrange(1_000_000_000)


def photo(seed: int) -> bytes:
    """A made-up picture, different for every seed and the same within a run
    for one seed, so a photo search finds the point it was indexed under. Never
    a real camera frame."""
    rng = random.Random(RUN_SEED * 1_000 + seed)
    image = Image.new("RGB", (480, 360), tuple(rng.randrange(256) for _ in range(3)))
    draw = ImageDraw.Draw(image)
    for _ in range(40):
        box = (
            sorted(rng.randrange(480) for _ in range(2)),
            sorted(rng.randrange(360) for _ in range(2)),
        )
        draw.rectangle(
            (box[0][0], box[1][0], box[0][1], box[1][1]),
            fill=tuple(rng.randrange(256) for _ in range(3)),
        )
    out = io.BytesIO()
    image.save(out, "JPEG", quality=90)
    return out.getvalue()
