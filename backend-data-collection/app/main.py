import os
from typing import Annotated

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from packages.supabase import SupaBase

load_dotenv()

app = FastAPI()

db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

# Shared with every other service via packages.supabase.SupaBase (#24) -
# bound as a plain module-level name so Depends(get_caller_id) and tests'
# app.dependency_overrides[get_caller_id] keep working unchanged.
get_caller_id = db.get_caller_id


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
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    return db.get_photos()


@app.get("/upload/{id}")
async def get_photo(id: int, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    return db.get_photo(id)


@app.delete("/upload/{id}")
async def delete_photo(id: int, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    db.dele_photo(id)
    return "ok"
