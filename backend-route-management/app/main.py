import os

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from packages.supabase import SupaBase

from .models import RouteCreate, RouteResponse

load_dotenv()

app = FastAPI()

db = SupaBase(os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_PUBLISHABLE_KEY"))


@app.get("/")
async def root():
    return {"service": "backend-route-management", "status": "ok"}


@app.post("/routes")
async def create_route(route: RouteCreate):
    result = db.client.table("routes").insert(route.model_dump()).execute()
    return result.data


@app.get("/routes")
async def list_routes() -> list[RouteResponse]:
    result = db.client.table("routes").select("*").execute()
    return result.data


@app.get("/routes/{id}")
async def get_route(id: str) -> RouteResponse:
    result = db.client.table("routes").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Route not found")
    return result.data[0]


@app.delete("/routes/{id}")
async def delete_route(id: str):
    db.client.table("routes").delete().eq("id", id).execute()
    return "ok"
