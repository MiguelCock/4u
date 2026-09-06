import os

from dotenv import load_dotenv
from fastapi import FastAPI, File, HTTPException, UploadFile
from packages.supabase import SupaBase

from .models import AnchorPointCreate, AnchorPointResponse, BuildingResponse

load_dotenv()

app = FastAPI()

db = SupaBase(os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_PUBLISHABLE_KEY"))


@app.get("/")
async def root():
    return {"service": "backend-map-management", "status": "ok"}


@app.post("/anchor-points/upload-image")
async def upload_anchor_point_image(file: UploadFile = File(...)):
    url = db.upload_image("anchor-points", file.file, file.filename)
    return {"url": url}


@app.post("/anchor-points")
async def create_anchor_point(anchor_point: AnchorPointCreate):
    result = db.client.table("anchor_points").insert(anchor_point.model_dump()).execute()
    return result.data


@app.get("/anchor-points")
async def list_anchor_points() -> list[AnchorPointResponse]:
    result = db.client.table("anchor_points").select("*").execute()
    return result.data


@app.get("/anchor-points/{id}")
async def get_anchor_point(id: str) -> AnchorPointResponse:
    result = db.client.table("anchor_points").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Anchor point not found")
    return result.data[0]


@app.get("/buildings")
async def list_buildings() -> list[BuildingResponse]:
    result = db.client.table("buildings").select("*").execute()
    return result.data


@app.get("/buildings/{id}")
async def get_building(id: str) -> BuildingResponse:
    result = db.client.table("buildings").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Building not found")
    return result.data[0]
