"""Removes the building's name from the end of existing point names, the way
POST/PATCH /anchor-points do for new ones (app/names.py).

From backend-map-management/:
    uv run python -m scripts.strip_building_names           # only lists
    uv run python -m scripts.strip_building_names --apply   # changes the data

A point whose new name would repeat another in its building is left alone for
an admin. Routes use ids, so they're not affected.
"""

import collections
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from packages.db_errors import select_all
from supabase import create_client

from app.names import name_without_building


def main(apply: bool) -> None:
    load_dotenv(Path(__file__).resolve().parents[1] / ".env")
    client = create_client(
        os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    )

    def rows(table: str, columns: str) -> list[dict]:
        return select_all(lambda: client.table(table).select(columns).order("id"))

    places = {p["id"]: p["name"] for p in rows("places", "id,name")}
    buildings = {b["id"]: b for b in rows("buildings", "id,name,place_id")}
    points = rows("anchor_points", "id,building_id,location_description")

    names_in_building = collections.defaultdict(collections.Counter)
    for point in points:
        if point["location_description"]:
            key = point["location_description"].strip().lower()
            names_in_building[point["building_id"]][key] += 1

    changes, clashes = [], []
    for point in points:
        old = point["location_description"]
        building = buildings.get(point["building_id"])
        if not old or not building:
            continue
        new = name_without_building(
            old, building["name"], places.get(building["place_id"])
        )
        if new == old:
            continue
        taken = names_in_building[point["building_id"]]
        (clashes if taken[new.lower()] else changes).append((point, new, building))
        taken[new.lower()] += 1

    for point, new, building in changes:
        print(f"{building['name']}: {point['location_description']!r} -> {new!r}")
    print(f"\n{len(changes)} to rename, of {len(points)} points.")
    if clashes:
        print(f"\n{len(clashes)} left alone (the new name is already in use):")
        for point, new, building in clashes:
            print(f"  {building['name']}: {point['location_description']!r} -> {new!r}")
    if not apply:
        print("\nNothing changed. Run with --apply to rename.")
        return
    for point, new, _ in changes:
        client.table("anchor_points").update({"location_description": new}).eq(
            "id", point["id"]
        ).execute()
    print(f"\nRenamed {len(changes)}.")


if __name__ == "__main__":
    main("--apply" in sys.argv[1:])
