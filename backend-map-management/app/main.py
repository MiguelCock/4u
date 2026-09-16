import os

from dotenv import load_dotenv
from fastapi import FastAPI, File, HTTPException, UploadFile
from packages.supabase import SupaBase

from .models import (
    AnchorPointCreate,
    AnchorPointPhotoCreate,
    AnchorPointPhotoResponse,
    AnchorPointResponse,
    AnchorPointUpdate,
    BuildingCreate,
    BuildingResponse,
    BuildingUpdate,
    PlaceCreate,
    PlaceResponse,
    PlaceUpdate,
)

load_dotenv()

app = FastAPI()

db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)


@app.get("/")
async def root():
    return {"service": "backend-map-management", "status": "ok"}


@app.post("/anchor-points/upload-image")
async def upload_anchor_point_image(file: UploadFile = File(...)):
    url = db.upload_image("anchor-points", file.file, file.filename)
    return {"url": url}


@app.post("/anchor-points")
async def create_anchor_point(anchor_point: AnchorPointCreate):
    result = (
        db.client.table("anchor_points").insert(anchor_point.model_dump()).execute()
    )
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


@app.patch("/anchor-points/{id}")
async def update_anchor_point(id: str, anchor_point: AnchorPointUpdate):
    result = (
        db.client.table("anchor_points")
        .update(anchor_point.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.delete("/anchor-points/{id}")
async def delete_anchor_point(id: str):
    db.client.table("anchor_points").delete().eq("id", id).execute()
    return "ok"


@app.post("/anchor-points/{id}/photos")
async def create_anchor_point_photo(id: str, photo: AnchorPointPhotoCreate):
    payload = {**photo.model_dump(), "anchor_point_id": id}
    result = db.client.table("anchor_point_photos").insert(payload).execute()
    return result.data


@app.get("/anchor-points/{id}/photos")
async def list_anchor_point_photos(id: str) -> list[AnchorPointPhotoResponse]:
    result = (
        db.client.table("anchor_point_photos")
        .select("*")
        .eq("anchor_point_id", id)
        .execute()
    )
    return result.data


@app.get("/anchor-point-photos")
async def list_all_anchor_point_photos() -> list[AnchorPointPhotoResponse]:
    result = db.client.table("anchor_point_photos").select("*").execute()
    return result.data


@app.delete("/anchor-point-photos/{id}")
async def delete_anchor_point_photo(id: str):
    db.client.table("anchor_point_photos").delete().eq("id", id).execute()
    return "ok"


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


@app.post("/buildings")
async def create_building(building: BuildingCreate):
    result = db.client.table("buildings").insert(building.model_dump()).execute()
    return result.data


@app.patch("/buildings/{id}")
async def update_building(id: str, building: BuildingUpdate):
    result = (
        db.client.table("buildings")
        .update(building.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.delete("/buildings/{id}")
async def delete_building(id: str):
    db.client.table("buildings").delete().eq("id", id).execute()
    return "ok"


@app.post("/places")
async def create_place(place: PlaceCreate):
    result = db.client.table("places").insert(place.model_dump()).execute()
    return result.data


@app.get("/places")
async def list_places() -> list[PlaceResponse]:
    result = db.client.table("places").select("*").execute()
    return result.data


@app.get("/places/{id}")
async def get_place(id: str) -> PlaceResponse:
    result = db.client.table("places").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Place not found")
    return result.data[0]


@app.patch("/places/{id}")
async def update_place(id: str, place: PlaceUpdate):
    result = (
        db.client.table("places")
        .update(place.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.delete("/places/{id}")
async def delete_place(id: str):
    db.client.table("places").delete().eq("id", id).execute()
    return "ok"
