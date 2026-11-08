"""What the app reads from each endpoint it calls: the fields that, if they
disappeared or changed shape, would break a screen. Collected from the app's
code (application/lib/: every `['field']` read on a response). A rewritten or
changed service must keep these.

Each entry: (name, path, fields every item must have). The path's {names} are
filled from the test campus. A path whose answer is a list is checked item by
item; an object, as is.
"""

PLACE = {"id", "name", "code", "latitude", "longitude", "is_active", "updated_at"}
BUILDING = {
    "id",
    "place_id",
    "name",
    "code",
    "latitude",
    "longitude",
    "floors",
    "is_active",
    "updated_at",
}
POINT = {
    "id",
    "building_id",
    "latitude",
    "longitude",
    "altitude",
    "floor",
    "status",
    "location_type_id",
    "location_description",
    "metadata",
    "updated_at",
}
PHOTO = {"id", "anchor_point_id", "image_url", "heading", "updated_at"}
CONNECTION = {
    "id",
    "anchor_point_a_id",
    "anchor_point_b_id",
    "distance_meters",
    "notes",
    "updated_at",
}
ROUTE = {
    "id",
    "name",
    "building_id",
    "start_anchor_id",
    "end_anchor_id",
    "waypoint_anchor_ids",
}
SESSION = {
    "id",
    "user_id",
    "route_id",
    "building_id",
    "status",
    "start_time",
    "end_time",
}
LOG = {
    "session_id",
    "gps_lat",
    "gps_long",
    "corrected_lat",
    "corrected_long",
    "anchor_match_id",
    "debug",
}
PROFILE = {"id", "full_name", "role_id", "is_active", "preferences"}
FEEDBACK = {"id", "user_id", "session_id", "comment", "created_at"}
CHANGES = {
    "full",
    "next_since",
    "deleted",
    "places",
    "buildings",
    "anchor_points",
    "anchor_point_photos",
    "anchor_point_connections",
}
APP_VERSION = {"latest", "min_supported", "download_url"}
INDEX_STATUS = {"photo_ids"}

# Read by admins (most screens) and by users (trip planning and the trip).
ADMIN_READS = [
    ("places", "/map/places", PLACE),
    ("buildings", "/map/buildings", BUILDING),
    ("points", "/map/anchor-points", POINT),
    ("point", "/map/anchor-points/{point}", POINT),
    ("point photos", "/map/anchor-points/{point}/photos", PHOTO),
    ("point connections", "/map/anchor-points/{point}/connections", CONNECTION),
    ("all photos", "/map/anchor-point-photos", PHOTO),
    ("connections", "/map/anchor-point-connections", CONNECTION),
    ("changes", "/map/changes?since={since}", CHANGES),
    ("routes", "/route/routes", ROUTE),
    ("route", "/route/routes/{route}", ROUTE),
    ("profiles", "/user/profiles", PROFILE),
    ("sessions", "/navigation/sessions", SESSION),
    ("trip logs", "/navigation/logs?session_id={session}", LOG),
    ("feedback", "/navigation/feedback", FEEDBACK),
    ("photo search status", "/ai-training/index_status", INDEX_STATUS),
]
USER_READS = [
    ("own profile", "/user/profiles/{user}", PROFILE),
    ("places", "/map/places", PLACE),
    ("buildings", "/map/buildings", BUILDING),
    ("points", "/map/anchor-points", POINT),
    ("connections", "/map/anchor-point-connections", CONNECTION),
    ("active sessions", "/navigation/sessions/active", SESSION),
]
PUBLIC_READS = [("app version", "/user/app-version", APP_VERSION)]
