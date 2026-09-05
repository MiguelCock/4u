from fastapi import FastAPI, UploadFile, File
from .models import ImageMetaData, ImageMetaDataResponse
from dotenv import load_dotenv
from packages.supabase import SupaBase
import os

load_dotenv()

app = FastAPI()

db = SupaBase(os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_PUBLISHABLE_KEY"))


@app.get("/")
async def root():
    return {"service": "backend-data-collection", "status": "ok"}


@app.post("/upload")
async def process_image_json(request: ImageMetaData, image: UploadFile = File(...)):
    img = image.file
    db.post_photos(img)
    return "ok"


@app.get("/upload")
async def process_image_json():
    result: list[ImageMetaDataResponse] = []
    a = db.get_photos()
    return result


@app.get("/upload:id")
async def process_image_json(id: int):
    result: ImageMetaDataResponse = []
    a = db.get_photo(id)
    return result


@app.delete("/upload:id")
async def process_image_json(id: int):
    a = db.dele_photo(id)
    return "ok"