"""Copies photo search's collections from one Qdrant to another (E2): every
vector and payload, the collection's settings and its payload indexes. No model
work, so it's quick and gives exactly the same answers. Then checks the counts
and a sample of points match. It never changes or deletes the source.

    SRC_QDRANT_URL=... SRC_QDRANT_KEY=... DST_QDRANT_URL=... DST_QDRANT_KEY=... \\
      python scripts/qdrant_copy.py

On the server, run it inside ai-training's container (it has httpx), which
reaches both the cloud and the local "qdrant":

    sudo docker exec -i -e SRC_QDRANT_URL=... -e SRC_QDRANT_KEY=... \\
      -e DST_QDRANT_URL=http://qdrant:6333 -e DST_QDRANT_KEY=... \\
      4u-ai-training-1 /app/.venv/bin/python - < scripts/qdrant_copy.py
"""

import os
import random
import sys

import httpx

BATCH = 128


def client(prefix: str) -> httpx.Client:
    return httpx.Client(
        base_url=os.environ[f"{prefix}_QDRANT_URL"].rstrip("/"),
        headers={"api-key": os.environ[f"{prefix}_QDRANT_KEY"]},
        timeout=120,
    )


def result(response: httpx.Response):
    response.raise_for_status()
    return response.json()["result"]


def copy_collection(src: httpx.Client, dst: httpx.Client, name: str) -> int:
    info = result(src.get(f"/collections/{name}"))
    vectors = info["config"]["params"]["vectors"]
    existing = {c["name"] for c in result(dst.get("/collections"))["collections"]}
    if name not in existing:
        result(dst.put(f"/collections/{name}", json={"vectors": vectors}))
    for field, schema in (info.get("payload_schema") or {}).items():
        result(
            dst.put(
                f"/collections/{name}/index",
                params={"wait": "true"},
                json={"field_name": field, "field_schema": schema["data_type"]},
            )
        )

    copied, offset = 0, None
    while True:
        body = {"limit": BATCH, "with_payload": True, "with_vector": True}
        if offset is not None:
            body["offset"] = offset
        page = result(src.post(f"/collections/{name}/points/scroll", json=body))
        points = [
            {"id": p["id"], "vector": p["vector"], "payload": p.get("payload") or {}}
            for p in page["points"]
        ]
        if points:
            result(
                dst.put(
                    f"/collections/{name}/points",
                    params={"wait": "true"},
                    json={"points": points},
                )
            )
            copied += len(points)
        offset = page.get("next_page_offset")
        if offset is None:
            return copied


def check(src: httpx.Client, dst: httpx.Client, name: str) -> None:
    counts = [
        result(c.post(f"/collections/{name}/points/count", json={"exact": True}))["count"]
        for c in (src, dst)
    ]
    if counts[0] != counts[1]:
        sys.exit(f"{name}: {counts[0]} points in the source, {counts[1]} copied")
    ids = [
        p["id"]
        for p in result(
            src.post(
                f"/collections/{name}/points/scroll",
                json={"limit": 1000, "with_payload": False, "with_vector": False},
            )
        )["points"]
    ]
    sample = random.sample(ids, min(25, len(ids)))
    if not sample:
        print(f"{name}: empty, nothing to compare")
        return
    body = {"ids": sample, "with_payload": True, "with_vector": True}
    a = {p["id"]: p for p in result(src.post(f"/collections/{name}/points", json=body))}
    b = {p["id"]: p for p in result(dst.post(f"/collections/{name}/points", json=body))}
    for point_id in sample:
        if a[point_id]["payload"] != b[point_id]["payload"] or any(
            abs(x - y) > 1e-6 for x, y in zip(a[point_id]["vector"], b[point_id]["vector"], strict=True)
        ):
            sys.exit(f"{name}: point {point_id} differs after copying")
    print(f"{name}: {counts[1]} points, and {len(sample)} sampled match")


def main() -> None:
    src, dst = client("SRC"), client("DST")
    names = [c["name"] for c in result(src.get("/collections"))["collections"]]
    for name in names:
        print(f"{name}: copied {copy_collection(src, dst, name)}")
        check(src, dst, name)


if __name__ == "__main__":
    main()
