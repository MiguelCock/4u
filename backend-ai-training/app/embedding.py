import hashlib
import os
from pathlib import Path

import cv2
import httpx
import numpy as np
import torch
import torch.nn.functional as F
from torch import nn
from torchvision.models import EfficientNet_B0_Weights, efficientnet_b0, resnet50
from torchvision.transforms import Normalize

_IMAGE_SIZE = 224
_NORMALIZE = Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])

# Which model embeds photos (EMBEDDING_MODEL). Each one has its own Qdrant
# collection, since vectors from different models can't be compared: a
# switch needs a re-index (admin "Re-index verified points"), and going back
# finds the old collection still there.
#
# eigenplaces (default): EigenPlaces ResNet50, trained for visual place
#   recognition (Berton et al., ICCV 2023). On the campus anchor photos it
#   told nearby places from far ones far better than effnet (AUC 0.83 vs
#   0.75, scripts/benchmark_models.py), at ~0.3 s per photo on 2 CPU threads.
# effnet: the first model, EfficientNet-B0 trained for ImageNet
#   classification. Pair it with POSITIONING_MIN_MATCH_SCORE=0.75.
MODEL_NAME = os.environ.get("EMBEDDING_MODEL", "eigenplaces")
_MODELS = {
    "effnet": ("anchor_point_photos", 1280),
    "eigenplaces": ("anchor_point_photos_eigenplaces", 2048),
}
if MODEL_NAME not in _MODELS:
    raise RuntimeError(
        f"EMBEDDING_MODEL={MODEL_NAME!r}; expected one of {', '.join(_MODELS)}"
    )
COLLECTION, VECTOR_SIZE = _MODELS[MODEL_NAME]

# EigenPlaces' published weights, pinned by release and content.
_EIGENPLACES_URL = (
    "https://github.com/gmberton/EigenPlaces/releases/download/v1.0/"
    "ResNet50_2048_eigenplaces.pth"
)
_EIGENPLACES_SHA256 = "98e8e21e9364a7e0990a9d7e1de5853b6d830f7f73d6bd9ee4f397575e0d41d1"
# The short side photos are scaled to, keeping their aspect ratio.
_EIGENPLACES_SHORT_SIDE = 384

_model: torch.nn.Module | None = None


class _GeM(nn.Module):
    """Generalized-mean pooling, as in EigenPlaces' own layers.py."""

    def __init__(self, p: float = 3.0, eps: float = 1e-6):
        super().__init__()
        self.p = nn.Parameter(torch.ones(1) * p)
        self.eps = eps

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        pooled = F.avg_pool2d(x.clamp(min=self.eps).pow(self.p), x.shape[-2:])
        return pooled.pow(1.0 / self.p)


class _L2Norm(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return F.normalize(x, p=2.0, dim=1)


class _Flatten(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x[:, :, 0, 0]


class EigenPlacesNet(nn.Module):
    """EigenPlaces' GeoLocalizationNet_ for ResNet50/2048, re-declared here
    (MIT License, (c) 2023 Gabriele Berton, Gabriele Trivigno, Carlo Masone,
    Barbara Caputo - github.com/gmberton/EigenPlaces) instead of fetched
    through torch.hub, which would run that repo's code at load time. Module
    names match theirs, so their state_dict loads as is."""

    def __init__(self) -> None:
        super().__init__()
        self.backbone = nn.Sequential(*list(resnet50().children())[:-2])
        self.aggregation = nn.Sequential(
            _L2Norm(), _GeM(), _Flatten(), nn.Linear(2048, 2048), _L2Norm()
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.aggregation(self.backbone(x))


def _eigenplaces_weights() -> dict:
    path = (
        Path(torch.hub.get_dir()) / "checkpoints" / _EIGENPLACES_URL.rsplit("/", 1)[1]
    )
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        torch.hub.download_url_to_file(_EIGENPLACES_URL, str(path), progress=False)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != _EIGENPLACES_SHA256:
        path.unlink()
        raise RuntimeError(f"EigenPlaces weights checksum mismatch ({digest})")
    return torch.load(path, map_location="cpu", weights_only=True)


def _get_model() -> torch.nn.Module:
    # Lazy, not eager like this repo's usual `db = SupaBase(...)` pattern -
    # loading pretrained weights means a real network download (~20 MB for
    # effnet, ~90 MB for EigenPlaces), unlike constructing a Supabase/Qdrant
    # client. Importing this module (e.g. from a test) must not trigger
    # that download.
    global _model
    if _model is None:
        if MODEL_NAME == "effnet":
            model = efficientnet_b0(weights=EfficientNet_B0_Weights.DEFAULT)
        else:
            model = EigenPlacesNet()
            model.load_state_dict(_eigenplaces_weights())
        model.eval()
        _model = model
    return _model


def _decode_rgb(image_bytes: bytes) -> np.ndarray:
    array = np.frombuffer(image_bytes, dtype=np.uint8)
    image = cv2.imdecode(array, cv2.IMREAD_COLOR)
    return cv2.cvtColor(image, cv2.COLOR_BGR2RGB)


def load_and_resize(image_bytes: bytes, size: int = _IMAGE_SIZE) -> np.ndarray:
    """effnet's input: squashed to a size x size square."""
    array = np.frombuffer(image_bytes, dtype=np.uint8)
    image = cv2.imdecode(array, cv2.IMREAD_COLOR)
    image = cv2.resize(image, (size, size))
    return cv2.cvtColor(image, cv2.COLOR_BGR2RGB)


def load_keep_aspect(image_bytes: bytes, short_side: int) -> np.ndarray:
    """Scaled so the short side is [short_side], aspect ratio kept - squashing
    a 4:3 phone photo square distorts the very geometry places are told
    apart by."""
    rgb = _decode_rgb(image_bytes)
    h, w = rgb.shape[:2]
    scale = short_side / min(h, w)
    size = (max(1, round(w * scale)), max(1, round(h * scale)))
    return cv2.resize(rgb, size, interpolation=cv2.INTER_AREA)


def _to_tensor(rgb: np.ndarray) -> torch.Tensor:
    tensor = torch.from_numpy(rgb).permute(2, 0, 1).float() / 255.0
    return _NORMALIZE(tensor).unsqueeze(0)


def extract_embedding(image_bytes: bytes) -> list[float]:
    model = _get_model()
    with torch.no_grad():
        if MODEL_NAME == "effnet":
            tensor = _to_tensor(load_and_resize(image_bytes))
            features = model.features(tensor)
            pooled = model.avgpool(features)
            embedding = torch.flatten(pooled, 1)
        else:
            tensor = _to_tensor(load_keep_aspect(image_bytes, _EIGENPLACES_SHORT_SIDE))
            embedding = model(tensor)
    return embedding.squeeze(0).tolist()


def download_image(url: str) -> bytes:
    response = httpx.get(url, timeout=30.0)
    response.raise_for_status()
    return response.content
