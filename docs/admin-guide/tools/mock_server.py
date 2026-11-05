"""A made-up backend for taking the guide's screenshots.

Serves a `flutter build web --base-href /admin/` at /admin/, with an .env that
points back at this server, and answers sign-in and the backend paths the admin
screens use from the fictional data below. No real key, URL or row is ever read.

    python3 mock_server.py <build/web> [--port 8765]

POST /__language {"language": "es"} sets the admin's app language. POST
/__reset restores the data. See README.md.
"""

import argparse
import base64
import copy
import json
import mimetypes
import re
import struct
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ADMIN_ID = "00000000-0000-4000-8000-000000000001"
USER_ID = "00000000-0000-4000-8000-000000000002"
USER2_ID = "00000000-0000-4000-8000-000000000003"
NOW = "2026-11-02T15:00:00+00:00"
# A park on the map; the campus on it is fictional.
LAT, LNG = 6.2726, -75.5672
# Metres to degrees, close enough here.
M_LAT = 1 / 111_000
M_LNG = 1 / 110_500

PLACE_ID = "p-demo"
B_LIB, B_ENG, B_CAFE = "b-lib", "b-eng", "b-cafe"


def _at(x_m, y_m):
    return round(LAT + y_m * M_LAT, 7), round(LNG + x_m * M_LNG, 7)


def _point(id_, building, x_m, y_m, name=None, type_id=10, floor=0, status="verified"):
    lat, lng = _at(x_m, y_m)
    return {
        "id": id_,
        "building_id": building,
        "location_type_id": type_id,
        "floor": floor,
        "latitude": lat,
        "longitude": lng,
        "altitude": 1500.0,
        "location_description": name,
        "status": status,
        "metadata": {"indoor": True, "lighting": "normal"},
    }


def _demo_points():
    return [
        # Library: three floors, joined by stairs and an elevator.
        _point("lib-door", B_LIB, 0, 0, "Entrada principal", 1),
        _point("lib-hall", B_LIB, 7, 0),
        _point("lib-lobby", B_LIB, 14, 0, "Recepción", 14),
        _point("lib-stairs0", B_LIB, 21, 0, None, 4),
        _point("lib-lift0", B_LIB, 21, 7, None, 3),
        _point("lib-hall2", B_LIB, 28, 0),
        _point("lib-wc", B_LIB, 35, 0, "Baño mujeres", 7),
        _point("lib-stairs1", B_LIB, 21, 0.5, None, 4, floor=1),
        _point("lib-lift1", B_LIB, 21, 7.5, None, 3, floor=1),
        _point("lib-up-hall", B_LIB, 28, 1, floor=1),
        _point("lib-study", B_LIB, 35, 1, "Sala de estudio", 26, floor=1),
        _point("lib-stairs2", B_LIB, 21, 1, None, 4, floor=2),
        _point("lib-lift2", B_LIB, 21, 8, None, 3, floor=2),
        _point("lib-archive", B_LIB, 29, 2, "Archivo", 9, floor=2, status="pending"),
        # Engineering.
        _point("eng-door", B_ENG, 0, 40, "Entrada sur", 1),
        _point("eng-hall", B_ENG, 7, 40),
        _point("eng-lab", B_ENG, 14, 40, "Laboratorio de redes", 24),
        _point("eng-101", B_ENG, 21, 40, "Salón 101", 5),
        _point("eng-new", B_ENG, 28, 40, "Salón 102", 5, status="pending"),
        _point("eng-103", B_ENG, 35, 40, "Salón 103", 5, status="pending"),
        # The cafeteria, with a named point saved with an in-between type and
        # one point left unconnected, for the menu's notices.
        _point("caf-door", B_CAFE, 0, 80, "Entrada", 1),
        _point("caf-hall", B_CAFE, 8, 80),
        _point("caf-counter", B_CAFE, 15, 80, "Caja", 8),
        _point("caf-tables", B_CAFE, 22, 80, "Terraza", 10),
        _point("caf-loose", B_CAFE, 30, 85, "Máquina de café", 21),
        # Outdoor path between the buildings.
        _point("path-1", B_LIB, 0, 10, type_id=12),
        _point("path-2", B_LIB, 0, 20, type_id=12),
        _point("path-3", B_ENG, 0, 30, type_id=12),
        _point("path-4", B_ENG, 0, 52, type_id=12),
        _point("path-5", B_CAFE, 0, 66, type_id=12),
    ]


_LINKS = [
    ("lib-door", "lib-hall"),
    ("lib-hall", "lib-lobby"),
    ("lib-lobby", "lib-stairs0"),
    ("lib-stairs0", "lib-lift0"),
    ("lib-stairs0", "lib-hall2"),
    ("lib-hall2", "lib-wc"),
    ("lib-stairs0", "lib-stairs1"),
    ("lib-lift0", "lib-lift1"),
    ("lib-stairs1", "lib-lift1"),
    ("lib-stairs1", "lib-up-hall"),
    ("lib-up-hall", "lib-study"),
    ("lib-stairs1", "lib-stairs2"),
    ("lib-lift1", "lib-lift2"),
    ("lib-door", "path-1"),
    ("path-1", "path-2"),
    ("path-2", "path-3"),
    ("path-3", "eng-door"),
    ("eng-door", "eng-hall"),
    ("eng-hall", "eng-lab"),
    ("eng-lab", "eng-101"),
    ("eng-door", "path-4"),
    ("path-4", "path-5"),
    ("path-5", "caf-door"),
    ("caf-door", "caf-hall"),
    ("caf-hall", "caf-counter"),
    ("caf-counter", "caf-tables"),
    # Old mistakes the menu lists: too long, and a floor change with no stairs.
    ("lib-wc", "eng-101"),
    ("lib-hall2", "lib-up-hall"),
]


def _distance(a, b):
    dy = (a["latitude"] - b["latitude"]) / M_LAT
    dx = (a["longitude"] - b["longitude"]) / M_LNG
    return round((dx * dx + dy * dy) ** 0.5, 1)


def demo_data():
    return _with_uuid_ids(_named_data())


def _with_uuid_ids(data):
    """Readable ids above, real-looking ones in the app: it shows the start of
    an unnamed point's id."""
    raw = json.dumps(data)
    for point in _demo_points():
        fake = str(uuid.uuid5(uuid.NAMESPACE_URL, "demo:" + point["id"]))
        raw = raw.replace(f'"{point["id"]}"', f'"{fake}"')
    return json.loads(raw)


def _named_data():
    points = _demo_points()
    by_id = {p["id"]: p for p in points}
    connections = []
    for i, (a, b) in enumerate(_LINKS):
        low, high = sorted((a, b))
        connections.append(
            {
                "id": f"c-{i}",
                "anchor_point_a_id": low,
                "anchor_point_b_id": high,
                "distance_meters": _distance(by_id[a], by_id[b]),
                "distance_manual": False,
                "notes": "Tres escalones hacia abajo" if a == "lib-hall" else None,
                "created_by": ADMIN_ID,
                "created_at": NOW,
            }
        )
    photos = []
    headings = [0, 90, 180, 270]
    for point in points:
        if point["id"] in ("lib-archive", "eng-new", "path-5"):
            continue
        for i, heading in enumerate(headings):
            photos.append(
                {
                    "id": f"ph-{point['id']}-{i}",
                    "anchor_point_id": point["id"],
                    "image_url": f"/demo-photo/{i}.png",
                    "heading": heading,
                    "captured_by": ADMIN_ID,
                    "captured_at": NOW,
                }
            )
    route_ids = ["lib-door", "lib-hall", "lib-lobby", "lib-stairs0", "lib-hall2", "lib-wc"]
    session = "s-demo-1"
    logs = []
    for i in range(36):
        t = i / 35
        x, y = 35 * t, 2.5 + (1.5 if i % 7 == 0 else 0.5)
        lat, lng = _at(x, y)
        clat, clng = _at(x, 0.4)
        logs.append(
            {
                "id": f"log-{i}",
                "session_id": session,
                "timestamp": f"2026-11-02T14:{10 + i // 12:02d}:{(i * 5) % 60:02d}+00:00",
                "gps_lat": lat,
                "gps_long": lng,
                "gps_accuracy": 4.0,
                "heading": 90.0,
                "corrected_lat": clat,
                "corrected_long": clng,
                "correction_error": 2.4,
                "anchor_match_id": route_ids[min(int(t * 6), 5)] if i % 6 == 0 else None,
                "confidence_score": 0.82 if i % 6 == 0 else None,
                "raw_image_url": None,
                "debug": {
                    "heading_source": "gyro",
                    "heading_reliable": True,
                    "floor": 0,
                    "pressure_hpa": 846.2,
                    "cues": [
                        {
                            "at": "2026-11-02T14:10:00Z",
                            "type": "start_walking",
                            "text": "Camina hacia adelante unos 20 pasos.",
                        }
                    ]
                    if i == 0
                    else [],
                },
            }
        )
    return {
        "places": [
            {
                "id": PLACE_ID,
                "code": "DEMO",
                "name": "Universidad Demo",
                "latitude": LAT,
                "longitude": LNG,
                "address": "Calle Ficticia 1",
                "is_active": True,
            }
        ],
        "buildings": [
            _building(B_LIB, "BIB", "Biblioteca", 0, 0, 3, True),
            _building(B_ENG, "ING", "Edificio de Ingeniería", 0, 40, 1, False),
            _building(B_CAFE, "CAF", "Cafetería", 0, 80, 1, False),
        ],
        "anchor-points": points,
        "anchor-point-connections": connections,
        "anchor-point-photos": photos,
        "routes": [
            {
                "id": "r-demo",
                "building_id": B_LIB,
                "name": "Entrada principal to Baño mujeres",
                "start_anchor_id": route_ids[0],
                "end_anchor_id": route_ids[-1],
                "waypoint_anchor_ids": route_ids[1:-1],
                "created_by": USER_ID,
            }
        ],
        "sessions": [
            {
                "id": session,
                "user_id": USER_ID,
                "building_id": B_LIB,
                "route_id": "r-demo",
                "start_position": None,
                "device_info": {"platform": "android", "app_version": "0.5.5"},
                "start_time": "2026-11-02T14:10:00+00:00",
                "end_time": "2026-11-02T14:13:00+00:00",
                "status": "completed",
                "end_position": None,
            },
            {
                "id": "s-demo-2",
                "user_id": USER2_ID,
                "building_id": B_ENG,
                "route_id": "r-demo",
                "start_position": None,
                "device_info": {"platform": "android", "app_version": "0.5.5"},
                "start_time": "2026-11-02T14:55:00+00:00",
                "end_time": None,
                "status": "active",
                "end_position": None,
            },
        ],
        "logs": logs,
        "feedback": [
            {
                "id": "f-1",
                "user_id": USER_ID,
                "session_id": session,
                "comment": "La indicación del baño llegó justo a tiempo.",
                "created_at": "2026-11-02T14:14:00+00:00",
            }
        ],
        "profiles": [
            _profile(ADMIN_ID, "Ana Administradora", 2),
            _profile(USER_ID, "Luis Usuario", 1),
            _profile(USER2_ID, "Marta Ejemplo", 1),
            {**_profile("00000000-0000-4000-8000-000000000004", "Pedro Inactivo", 1), "is_active": False},
        ],
    }


def _building(id_, code, name, x_m, y_m, floors, elevator):
    lat, lng = _at(x_m, y_m)
    return {
        "id": id_,
        "place_id": PLACE_ID,
        "code": code,
        "name": name,
        "address": None,
        "latitude": lat,
        "longitude": lng,
        "floors": floors,
        "has_elevator": elevator,
        "has_stairs": True,
        "is_active": True,
    }


def _profile(id_, name, role):
    return {
        "id": id_,
        "place_id": PLACE_ID,
        "role_id": role,
        "full_name": name,
        "avatar_url": None,
        "phone": None,
        "preferences": {},
        "is_active": True,
        "created_at": NOW,
        "updated_at": NOW,
    }


def _jwt():
    def part(value):
        raw = json.dumps(value).encode()
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    payload = {
        "sub": ADMIN_ID,
        "aud": "authenticated",
        "role": "authenticated",
        "email": "ana@demo.example",
        "exp": int(time.time()) + 86400,
    }
    return f"{part({'alg': 'none', 'typ': 'JWT'})}.{part(payload)}.demo"


def _session():
    return {
        "access_token": _jwt(),
        "token_type": "bearer",
        "expires_in": 86400,
        "expires_at": int(time.time()) + 86400,
        "refresh_token": "demo-refresh",
        "user": {
            "id": ADMIN_ID,
            "aud": "authenticated",
            "role": "authenticated",
            "email": "ana@demo.example",
            "app_metadata": {},
            "user_metadata": {},
            "created_at": NOW,
        },
    }


def _demo_photo(index):
    """A plain gradient standing in for a photo, as a PNG."""
    tops = [(150, 180, 210), (170, 190, 150), (200, 180, 150), (170, 170, 200)]
    top = tops[int(index) % 4]
    width, height = 320, 240
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        shade = y / height
        pixel = bytes(int(c * (1 - 0.55 * shade)) for c in top)
        rows += pixel * width

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(rows)))
        + chunk(b"IEND", b"")
    )


class State:
    data = demo_data()
    language = "es"
    build_dir = Path(".")
    port = 8765


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "*")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, value, status=200):
        self._send(status, json.dumps(value).encode())

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw) if raw else {}
        except ValueError:
            return {}

    def do_OPTIONS(self):
        self._send(204)

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/admin":
            self.send_response(301)
            self.send_header("Location", "/admin/")
            self.end_headers()
            return
        if path.startswith("/admin/"):
            self._static(path[len("/admin/") :])
            return
        match = re.fullmatch(r"/demo-photo/(\d+)\.png", path)
        if match:
            self._send(200, _demo_photo(match.group(1)), "image/png")
            return
        self._api("GET", path, parse_qs(url.query), None)

    def do_POST(self):
        url = urlparse(self.path)
        self._api("POST", url.path, parse_qs(url.query), self._body())

    def do_PATCH(self):
        url = urlparse(self.path)
        self._api("PATCH", url.path, parse_qs(url.query), self._body())

    def do_PUT(self):
        self.do_PATCH()

    def do_DELETE(self):
        url = urlparse(self.path)
        self._api("DELETE", url.path, parse_qs(url.query), None)

    def _static(self, relative):
        relative = relative or "index.html"
        if relative == "assets/.env":
            base = f"http://localhost:{State.port}"
            env = (
                f"API_GATEWAY_URL={base}\n"
                f"SUPABASE_URL={base}\n"
                "SUPABASE_PUBLISHABLE_KEY=demo-not-a-real-key\n"
            )
            self._send(200, env.encode(), "text/plain")
            return
        root = State.build_dir.resolve()
        target = (root / relative).resolve()
        if target.is_dir():
            target = target / "index.html"
        if root not in target.parents or not target.is_file():
            target = root / "index.html"
        kind = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if target.suffix == ".wasm":
            kind = "application/wasm"
        self._send(200, target.read_bytes(), kind)

    def _api(self, method, path, query, body):
        data = State.data
        if path == "/__language":
            State.language = body["language"]
            self._json("ok")
            return
        if path == "/__reset":
            State.data = demo_data()
            self._json("ok")
            return
        if path.startswith("/auth/v1/"):
            self._json({} if path.endswith("logout") else _session())
            return
        if path.startswith("/rest/v1/") or path.startswith("/realtime/"):
            self._json([])
            return

        service, _, rest = path.lstrip("/").partition("/")
        rest = "/" + rest
        if service == "user":
            self._user(method, rest, body)
        elif service == "map":
            self._map(method, rest, body)
        elif service == "route":
            if rest == "/routes":
                self._json(data["routes"])
            elif rest.startswith("/routes/"):
                self._json(data["routes"][0])
            else:
                self._json({})
        elif service == "navigation":
            self._navigation(method, rest, query, body)
        elif service == "ai-training":
            if rest == "/index_status":
                ids = [p["id"] for p in data["anchor-point-photos"]]
                # Two photos aren't searchable, for the menu's notice.
                self._json({"collection": "demo", "photo_ids": ids[:-2]})
            else:
                self._json({"status": "ok"})
        else:
            self._json({"detail": "Not found"}, 404)

    def _user(self, method, rest, body):
        profiles = State.data["profiles"]
        if rest == "/app-version":
            self._json({"latest": "0.5.5", "min_supported": "0.5.4", "download_url": "#"})
        elif rest == "/profiles" and method == "GET":
            self._json(profiles)
        elif rest == "/profiles/orphaned":
            self._json([])
        elif rest.startswith("/profiles/"):
            id_ = rest.split("/")[2]
            found = next((p for p in profiles if p["id"] == id_), None)
            if found is None:
                self._json({"detail": "Not found"}, 404)
                return
            if method == "PATCH":
                found.update(body)
            profile = copy.deepcopy(found)
            if id_ == ADMIN_ID:
                profile["preferences"] = {"language": State.language}
            self._json(profile)
        else:
            self._json({})

    def _map(self, method, rest, body):
        data = State.data
        parts = rest.strip("/").split("/")
        table = parts[0]
        if table not in ("places", "buildings", "anchor-points", "anchor-point-connections", "anchor-point-photos"):
            self._json({"service": "map"})
            return
        rows = data[table]
        if len(parts) == 3 and parts[2] == "connections":
            links = data["anchor-point-connections"]
            self._json(
                [c for c in links if parts[1] in (c["anchor_point_a_id"], c["anchor_point_b_id"])]
            )
            return
        if len(parts) == 3 and parts[2] == "photos":
            photos = data["anchor-point-photos"]
            self._json([f for f in photos if f["anchor_point_id"] == parts[1]])
            return
        if len(parts) == 1:
            if method == "GET":
                self._json(rows)
            else:
                row = {"id": str(uuid.uuid4()), "created_at": NOW, "status": "pending", **body}
                rows.append(row)
                self._json([row])
            return
        found = next((r for r in rows if r["id"] == parts[1]), None)
        if found is None:
            self._json({"detail": "Not found"}, 404)
        elif method == "PATCH":
            found.update(body)
            self._json([found] if table == "anchor-points" else found)
        elif method == "DELETE":
            rows.remove(found)
            self._json("ok")
        else:
            self._json(found)

    def _navigation(self, method, rest, query, body):
        data = State.data
        if rest.startswith("/guidance-reports"):
            self._json([])
        elif rest == "/feedback":
            self._json(data["feedback"])
        elif rest.startswith("/logs"):
            session = (query.get("session_id") or [""])[0]
            self._json([l for l in data["logs"] if l["session_id"] == session])
        elif rest in ("/sessions", "/sessions/active"):
            self._json(data["sessions"])
        else:
            self._json({})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("build_dir", type=Path)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    State.build_dir = args.build_dir
    State.port = args.port
    ThreadingHTTPServer(("localhost", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
