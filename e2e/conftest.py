"""Shared data for the flows: an admin builds a small map once per run, and the
contract tests read it. Every test talks only to the gateway (stack.py)."""

import httpx
import pytest

import stack


@pytest.fixture(scope="session", autouse=True)
def _stack_is_up():
    try:
        httpx.get(f"{stack.GATEWAY}/user/app-version", timeout=10).raise_for_status()
    except httpx.HTTPError as error:
        pytest.exit(
            f"No system at {stack.GATEWAY} ({error}). Run scripts/e2e.sh.", returncode=2
        )
    if not stack.PUBLISHABLE_KEY or not stack.SERVICE_ROLE_KEY:
        pytest.exit("Missing the local stack's keys. Run scripts/e2e.sh.", returncode=2)


@pytest.fixture(scope="session")
def admin() -> stack.Account:
    return stack.sign_up("admin")


@pytest.fixture(scope="session")
def user() -> stack.Account:
    return stack.sign_up("user")


@pytest.fixture(scope="session")
def campus(admin):
    """A university, a building, and three verified points 10 m apart in a
    line, each with a photo in photo search, connected A-B-C: the smallest map
    a trip can be planned on."""
    with admin.client() as api:
        place = _ok(
            api.post(
                "/map/places",
                json={
                    "code": stack.unique("U"),
                    "name": stack.unique("Universidad e2e"),
                    "latitude": stack.CAMPUS[0],
                    "longitude": stack.CAMPUS[1],
                },
            )
        )[0]
        building = _ok(
            api.post(
                "/map/buildings",
                json={
                    "place_id": place["id"],
                    "code": stack.unique("B"),
                    "name": stack.unique("Bloque e2e"),
                    "latitude": stack.CAMPUS[0],
                    "longitude": stack.CAMPUS[1],
                    "floors": 2,
                    "has_elevator": True,
                    "has_stairs": True,
                },
            )
        )[0]
        points = []
        for number, name in enumerate(("Entrada e2e", "Pasillo e2e", "Cafetería e2e")):
            latitude, longitude = stack.offset(10 * number)
            point = _ok(
                api.post(
                    "/map/anchor-points",
                    json={
                        "building_id": building["id"],
                        # Entrance, hallway, cafeteria: destinations need a name.
                        "location_type_id": (1, 10, 6)[number],
                        "latitude": latitude,
                        "longitude": longitude,
                        "floor": 0,
                        "location_description": name,
                        "metadata": {"indoor": True},
                    },
                )
            )[0]
            point["photos"] = [_add_photo(api, point, seed=100 + number)]
            points.append(point)
        connections = [
            _ok(
                api.post(
                    "/map/anchor-point-connections",
                    json={
                        "anchor_point_a_id": points[i]["id"],
                        "anchor_point_b_id": points[i + 1]["id"],
                    },
                )
            )[0]
            for i in range(2)
        ]
        for point in points:
            _ok(
                api.patch(
                    f"/map/anchor-points/{point['id']}",
                    json={"status": "verified", "expected": {"status": "pending"}},
                )
            )
            _ok(
                api.post("/ai-training/index_anchor", json=_index_body(building, point))
            )
    return {
        "place": place,
        "building": building,
        "points": points,
        "connections": connections,
    }


def _add_photo(api: httpx.Client, point: dict, seed: int) -> dict:
    upload = _ok(
        api.post(
            "/map/anchor-points/upload-image",
            # A random suffix, as the app adds: a name already in storage is refused.
            files={
                "file": (
                    stack.unique(f"e2e-{seed}") + ".jpg",
                    stack.photo(seed),
                    "image/jpeg",
                )
            },
        )
    )
    return _ok(
        api.post(
            f"/map/anchor-points/{point['id']}/photos",
            json={"image_url": upload["url"], "heading": 90},
        )
    )[0]


def _index_body(building: dict, point: dict) -> dict:
    return {
        "anchor_point_id": point["id"],
        "latitude": point["latitude"],
        "longitude": point["longitude"],
        "building_id": building["id"],
        "photos": [
            {"photo_id": p["id"], "image_url": p["image_url"], "heading": p["heading"]}
            for p in point["photos"]
        ],
    }


def _ok(response: httpx.Response):
    assert response.status_code < 300, (
        f"{response.request.method} {response.request.url.path}: "
        f"{response.status_code} {response.text[:500]}"
    )
    return response.json()


@pytest.fixture(scope="session")
def ok():
    return _ok


@pytest.fixture(scope="session")
def add_photo():
    return _add_photo
