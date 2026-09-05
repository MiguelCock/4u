from pydantic import BaseModel


class RouteCreate(BaseModel):
    building_id: str
    name: str
    start_anchor_id: str
    end_anchor_id: str
    waypoint_anchor_ids: list[str] = []


class RouteResponse(RouteCreate):
    id: str
