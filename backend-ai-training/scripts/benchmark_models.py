"""Compares image-embedding models for anchor-point matching. A development
tool, not part of the service.

The question each model has to answer is the one /search_similar asks: of
the anchor points near the user that face the same way, which one is the
user at? Test (a) asks it of the anchor photos themselves: each photo is a
query against every *other* anchor's photos within 60 m whose heading is
within 60 deg (the same gates backend-positioning applies), and the right
answer is the nearest such anchor. Photos of one anchor are taken from
one spot, so this is a proxy; real frames saved during test walks
(navigation_logs.raw_image_url) are the next, stronger test.

    uv run python scripts/benchmark_models.py session.json photos_dir \\
        [--models effnet dinov2_s eigenplaces megaloc]

session.json is backend-positioning/scripts/export_session.py's output (only
its anchors and photos are used for test a); photos_dir holds each anchor
photo as <photo id>.jpg. Latency is measured with 2 threads, like the
server.
"""

import argparse
import json
import math
import statistics
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import embedding

torch.set_num_threads(2)


def _read_rgb(path: Path) -> np.ndarray:
    image = cv2.imdecode(np.fromfile(path, dtype=np.uint8), cv2.IMREAD_COLOR)
    return cv2.cvtColor(image, cv2.COLOR_BGR2RGB)


def _keep_aspect(rgb: np.ndarray, short: int, multiple: int = 1) -> np.ndarray:
    h, w = rgb.shape[:2]
    scale = short / min(h, w)
    nh = max(multiple, round(h * scale / multiple) * multiple)
    nw = max(multiple, round(w * scale / multiple) * multiple)
    return cv2.resize(rgb, (nw, nh), interpolation=cv2.INTER_AREA)


_MEAN = torch.tensor([0.485, 0.456, 0.406]).view(3, 1, 1)
_STD = torch.tensor([0.229, 0.224, 0.225]).view(3, 1, 1)


def _tensor(rgb: np.ndarray) -> torch.Tensor:
    t = torch.from_numpy(rgb).permute(2, 0, 1).float() / 255.0
    return ((t - _MEAN) / _STD).unsqueeze(0)


class Effnet:
    """The model in production (app/embedding.py), unchanged."""

    name = "effnet"

    def embed(self, path: Path) -> np.ndarray:
        return np.array(embedding.extract_embedding(path.read_bytes()))


class Dinov2Small:
    name = "dinov2_s"

    def __init__(self):
        self.model = torch.hub.load("facebookresearch/dinov2", "dinov2_vits14").eval()

    def embed(self, path: Path) -> np.ndarray:
        x = _tensor(_keep_aspect(_read_rgb(path), 224, 14))
        with torch.no_grad():
            out = self.model.forward_features(x)
        cls = out["x_norm_clstoken"][0]
        patches = out["x_norm_patchtokens"][0].clamp(min=1e-6)
        gem = patches.pow(3).mean(0).pow(1 / 3)  # GeM over patch tokens
        return torch.cat([cls, gem]).numpy()


class EigenPlaces:
    name = "eigenplaces"

    def __init__(self, short=384):
        self.short = short
        self.model = torch.hub.load(
            "gmberton/eigenplaces",
            "get_trained_model",
            backbone="ResNet50",
            fc_output_dim=2048,
            trust_repo=True,
        ).eval()

    def embed(self, path: Path) -> np.ndarray:
        x = _tensor(_keep_aspect(_read_rgb(path), self.short))
        with torch.no_grad():
            return self.model(x)[0].numpy()


class MegaLoc:
    name = "megaloc"

    def __init__(self, short=322):
        self.short = short
        self.model = torch.hub.load(
            "gmberton/MegaLoc", "get_trained_model", trust_repo=True
        ).eval()

    def embed(self, path: Path) -> np.ndarray:
        x = _tensor(_keep_aspect(_read_rgb(path), self.short, 14))
        with torch.no_grad():
            return self.model(x)[0].numpy()


MODELS = {
    "effnet": Effnet,
    "dinov2_s": Dinov2Small,
    "eigenplaces": EigenPlaces,
    "megaloc": MegaLoc,
    # Smaller input: about half the CPU time.
    "megaloc_224": lambda: MegaLoc(short=224),
}


def _xy(lat, lng, lat0):
    return (lng * 111320 * math.cos(math.radians(lat0)), lat * 111320)


def _heading_diff(a, b):
    d = abs(a - b) % 360
    return 360 - d if d > 180 else d


def test_anchor_photos(model, anchors, photos, photos_dir: Path):
    lat0 = next(iter(anchors.values()))["latitude"]
    xy = {a: _xy(v["latitude"], v["longitude"], lat0) for a, v in anchors.items()}
    usable = [
        p
        for p in photos
        if (photos_dir / f"{p['id']}.jpg").exists() and p["anchor_point_id"] in xy
    ]
    vectors, times = {}, []
    for p in usable:
        start = time.perf_counter()
        v = model.embed(photos_dir / f"{p['id']}.jpg")
        times.append(time.perf_counter() - start)
        vectors[p["id"]] = v / (np.linalg.norm(v) + 1e-12)

    hits = total = 0
    near_scores, far_scores, errors = [], [], []
    for q in usable:
        qa = q["anchor_point_id"]
        pool = [
            p
            for p in usable
            if p["anchor_point_id"] != qa
            and math.dist(xy[p["anchor_point_id"]], xy[qa]) <= 60
            and (
                q["heading"] is None
                or p["heading"] is None
                or _heading_diff(q["heading"], p["heading"]) <= 60
            )
        ]
        if not pool:
            continue
        best_per_anchor = {}
        for p in pool:
            s = float(vectors[q["id"]] @ vectors[p["id"]])
            a = p["anchor_point_id"]
            best_per_anchor[a] = max(best_per_anchor.get(a, -2.0), s)
            d = math.dist(xy[a], xy[qa])
            if d < 8:
                near_scores.append(s)
            elif d > 20:
                far_scores.append(s)
        nearest = min(best_per_anchor, key=lambda a: math.dist(xy[a], xy[qa]))
        top = max(best_per_anchor, key=best_per_anchor.get)
        total += 1
        hits += top == nearest
        errors.append(math.dist(xy[top], xy[qa]))

    # Probability a random near pair outscores a random far pair (ROC AUC).
    far_sorted = np.sort(np.array(far_scores))
    auc = (
        float(
            np.mean(
                [np.searchsorted(far_sorted, s) / len(far_sorted) for s in near_scores]
            )
        )
        if near_scores and far_scores
        else float("nan")
    )
    return {
        "queries": total,
        "top1_is_nearest": hits / total if total else float("nan"),
        "top1_error_m_median": statistics.median(errors) if errors else float("nan"),
        "top1_within_8m": sum(e < 8 for e in errors) / len(errors)
        if errors
        else float("nan"),
        "near_score_median": statistics.median(near_scores)
        if near_scores
        else float("nan"),
        "far_score_median": statistics.median(far_scores)
        if far_scores
        else float("nan"),
        "near_vs_far_auc": auc,
        "ms_per_image": 1000 * statistics.median(times),
        "dims": len(next(iter(vectors.values()))),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("session")
    parser.add_argument("photos_dir")
    parser.add_argument("--models", nargs="*", default=list(MODELS))
    args = parser.parse_args()
    data = json.loads(Path(args.session).read_text())
    anchors = {a["id"]: a for a in data["anchors"]}
    photos = data["photos"]
    for name in args.models:
        try:
            model = MODELS[name]()
        except Exception as e:  # noqa: BLE001 - a model that won't load is a result too
            print(f"{name}: failed to load ({e})")
            continue
        r = test_anchor_photos(model, anchors, photos, Path(args.photos_dir))
        print(
            f"{name:12} top1=nearest {r['top1_is_nearest']:.2f}  top1<8m {r['top1_within_8m']:.2f}  "
            f"top1 err median {r['top1_error_m_median']:5.1f} m  AUC near>far {r['near_vs_far_auc']:.2f}  "
            f"near/far score {r['near_score_median']:.3f}/{r['far_score_median']:.3f}  "
            f"{r['ms_per_image']:.0f} ms/img  dim {r['dims']}  (n={r['queries']})",
            flush=True,
        )


if __name__ == "__main__":
    main()
