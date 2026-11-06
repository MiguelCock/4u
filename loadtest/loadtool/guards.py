"""What a simulated user may change. The test runs against production while the
real map is in use, so this isn't left to the scenario being written correctly:
every write goes through a guard, which refuses anything but the user's own
sandbox data and trip."""

import re


class UnsafeWrite(Exception):
    """A simulated user tried to change something that isn't theirs."""


READ_METHODS = {"GET", "HEAD", "OPTIONS"}

_POINT_PHOTOS = re.compile(r"^/map/anchor-points/([^/]+)/photos$")
_POINT = re.compile(r"^/map/anchor-points/([^/]+)$")
_SESSION = re.compile(r"^/navigation/sessions/([^/]+)$")


class WriteGuard:
    """[building_id] is the sandbox building, and [route] the (start, end) of
    the one saved route a navigating user may ask for."""

    def __init__(
        self,
        building_id: str | None = None,
        route: tuple[str, str] | None = None,
    ):
        self.building_id = building_id
        self.route = route
        self.points: set[str] = set()
        self.sessions: set[str] = set()

    def check(self, method: str, path: str, body: dict | None = None) -> None:
        method = method.upper()
        if method in READ_METHODS:
            return
        path = path.split("?", 1)[0]
        body = body or {}
        if self._allowed(method, path, body):
            return
        raise UnsafeWrite(f"refused {method} {path}")

    def _allowed(self, method: str, path: str, body: dict) -> bool:
        if method == "POST":
            return self._post_allowed(path, body)
        if method == "PATCH":
            if match := _POINT.match(path):
                # The literal "upload-image" isn't a point id, and never owned.
                return match.group(1) in self.points
            if match := _SESSION.match(path):
                return match.group(1) in self.sessions
        return False

    def _post_allowed(self, path: str, body: dict) -> bool:
        match path:
            case "/route/routes/find_or_create":
                # Returns the saved route, with no new row, as long as it's
                # still walkable (see trips.choose_route).
                return self.route is not None and self.route == (
                    body.get("start_anchor_id"),
                    body.get("end_anchor_id"),
                )
            case "/navigation/sessions":
                return True
            case "/navigation/logs" | "/positioning/correct_position":
                return body.get("session_id") in self.sessions
            case "/map/anchor-points":
                return (
                    self.building_id is not None
                    and body.get("building_id") == self.building_id
                )
            case "/map/anchor-points/upload-image":
                return self.building_id is not None
            case "/map/anchor-point-connections":
                return {
                    body.get("anchor_point_a_id"),
                    body.get("anchor_point_b_id"),
                } <= self.points
            case "/ai-training/index_anchor":
                return body.get("anchor_point_id") in self.points
        if match := _POINT_PHOTOS.match(path):
            return match.group(1) in self.points
        return False
