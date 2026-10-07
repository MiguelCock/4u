from pydantic import BaseModel


class RouteCreate(BaseModel):
    # Nullable as of the trip-planning work: a route created via
    # find_or_create spans whatever buildings its start/end anchors land
    # in, so this is "the building the trip starts in" at best, not a
    # hard scope - see db_schema/routes.sql.
    building_id: str | None = None
    name: str
    start_anchor_id: str
    end_anchor_id: str
    waypoint_anchor_ids: list[str] = []
    # Audit field, forced server-side to the verified caller on create -
    # same "don't trust a client-supplied identity field" principle #111
    # applied to profiles.id. Optional here only because rows created
    # before this field existed have it NULL.
    created_by: str | None = None


class RouteResponse(RouteCreate):
    id: str


class RouteFindOrCreate(BaseModel):
    start_anchor_id: str
    end_anchor_id: str
