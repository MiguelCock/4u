import os
from typing import Annotated

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from packages.supabase import SupaBase

load_dotenv()

app = FastAPI()

db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

# Match db_schema/roles.sql's seeded rows.
_ADMIN_ROLE_ID = 2


async def get_caller_id(authorization: str | None = Header(default=None)) -> str:
    """Verifies the caller's Supabase Auth bearer token for real (against
    Supabase itself, not a local check) and returns the real, verified
    caller id - copied verbatim from backend-user-management (#111), the
    reusable template for this rollout (#24). 401s on anything missing,
    malformed, or rejected by Supabase (expired/invalid token)."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="Missing bearer token")
    try:
        return db.get_user_id_from_token(token)
    except Exception as e:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from e


def _is_admin(caller_id: str) -> bool:
    result = db.client.table("profiles").select("role_id").eq("id", caller_id).execute()
    return bool(result.data) and result.data[0]["role_id"] == _ADMIN_ROLE_ID


@app.get("/")
async def root():
    return {"service": "backend-data-collection", "status": "ok"}


@app.post("/upload")
async def upload_photo(
    latitude: Annotated[float, Form()],
    longitude: Annotated[float, Form()],
    accuracy: Annotated[float, Form()],
    heading: Annotated[float | None, Form()] = None,
    image: UploadFile = File(...),
    caller_id: str = Depends(get_caller_id),
):
    db.post_photos(image.file, image.filename, latitude, longitude, accuracy, heading)
    return "ok"


@app.get("/upload")
async def list_photos(caller_id: str = Depends(get_caller_id)):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    return db.get_photos()


@app.get("/upload/{id}")
async def get_photo(id: int, caller_id: str = Depends(get_caller_id)):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    return db.get_photo(id)


@app.delete("/upload/{id}")
async def delete_photo(id: int, caller_id: str = Depends(get_caller_id)):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    db.dele_photo(id)
    return "ok"
