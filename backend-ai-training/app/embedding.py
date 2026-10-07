import cv2
import httpx
import numpy as np
import torch
from torchvision.models import EfficientNet_B0_Weights, efficientnet_b0
from torchvision.transforms import Normalize

_IMAGE_SIZE = 224
_NORMALIZE = Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])

_model: torch.nn.Module | None = None


def _get_model() -> torch.nn.Module:
    # Lazy, not eager like this repo's usual `db = SupaBase(...)` pattern -
    # loading pretrained weights means a real ~20MB network download, unlike
    # constructing a Supabase/Qdrant client. Importing this module (e.g. from
    # a test) must not trigger that download.
    global _model
    if _model is None:
        weights = EfficientNet_B0_Weights.DEFAULT
        model = efficientnet_b0(weights=weights)
        model.eval()
        _model = model
    return _model


def load_and_resize(image_bytes: bytes, size: int = _IMAGE_SIZE) -> np.ndarray:
    array = np.frombuffer(image_bytes, dtype=np.uint8)
    image = cv2.imdecode(array, cv2.IMREAD_COLOR)
    image = cv2.resize(image, (size, size))
    return cv2.cvtColor(image, cv2.COLOR_BGR2RGB)


def extract_embedding(image_bytes: bytes) -> list[float]:
    rgb = load_and_resize(image_bytes)
    tensor = torch.from_numpy(rgb).permute(2, 0, 1).float() / 255.0
    tensor = _NORMALIZE(tensor).unsqueeze(0)

    model = _get_model()
    with torch.no_grad():
        features = model.features(tensor)
        pooled = model.avgpool(features)
        embedding = torch.flatten(pooled, 1)
    return embedding.squeeze(0).tolist()


def download_image(url: str) -> bytes:
    response = httpx.get(url, timeout=30.0)
    response.raise_for_status()
    return response.content
