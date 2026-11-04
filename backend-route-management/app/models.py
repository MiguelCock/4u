from pydantic import BaseModel, model_validator


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
    # One or the other: a point, or a building, whose closest entrance by
    # walking becomes the end.
    end_anchor_id: str | None = None
    end_building_id: str | None = None

    @model_validator(mode="after")
    def _one_destination(self):
        if (self.end_anchor_id is None) == (self.end_building_id is None):
            raise ValueError("Send either end_anchor_id or end_building_id")
        return self
