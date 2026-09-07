import os
from typing import Annotated

from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, UploadFile
from packages.supabase import SupaBase

load_dotenv()

app = FastAPI()

db = SupaBase(os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_PUBLISHABLE_KEY"))


@app.get("/")
async def root():
    return {"service": "backend-data-collection", "status": "ok"}


@app.post("/upload")
async def upload_photo(
    latitude: Annotated[float, Form()],
    longitude: Annotated[float, Form()],
    accuracy: Annotated[float, Form()],
    image: UploadFile = File(...),
):
    db.post_photos(image.file, latitude, longitude, accuracy)
    return "ok"


@app.get("/upload")
async def list_photos():
    return db.get_photos()


@app.get("/upload/{id}")
async def get_photo(id: int):
    return db.get_photo(id)


@app.delete("/upload/{id}")
async def delete_photo(id: int):
    db.dele_photo(id)
    return "ok"
