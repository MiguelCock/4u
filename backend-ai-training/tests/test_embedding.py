import cv2
import numpy as np
import torch

from app import embedding
from app.embedding import EigenPlacesNet, load_and_resize, load_keep_aspect


def test_load_and_resize_produces_224x224_rgb_array():
    original = np.zeros((100, 50, 3), dtype=np.uint8)
    original[:, :, 0] = 255  # blue channel in BGR
    ok, encoded = cv2.imencode(".png", original)
    assert ok

    result = load_and_resize(encoded.tobytes())

    assert result.shape == (224, 224, 3)
    assert result.dtype == np.uint8
    # BGR->RGB conversion happened: the all-blue source shows up as the red
    # channel being empty and the blue channel populated after cv2's BGR
    # read, so post-conversion the red channel should be near-zero.
    assert result[..., 0].max() == 0


def test_load_keep_aspect_scales_the_short_side_only():
    original = np.zeros((480, 720, 3), dtype=np.uint8)
    ok, encoded = cv2.imencode(".png", original)
    assert ok
    result = load_keep_aspect(encoded.tobytes(), 384)
    assert result.shape == (384, 576, 3)


def test_eigenplaces_net_returns_a_unit_2048_vector():
    # Random weights - only the shape of the network is under test here;
    # the published weights are checked by SHA-256 when they load.
    torch.manual_seed(0)
    net = EigenPlacesNet().eval()
    with torch.no_grad():
        out = net(torch.rand(1, 3, 96, 128))
    assert out.shape == (1, 2048)
    assert torch.allclose(out.norm(dim=1), torch.ones(1), atol=1e-5)


def test_each_model_has_its_own_collection():
    # Vectors of different models can't be compared, and switching back
    # must find the old index intact.
    collections = {name: c for name, (c, _) in embedding._MODELS.items()}
    assert len(set(collections.values())) == len(collections)
    assert collections["effnet"] == "anchor_point_photos"
    assert embedding._MODELS["eigenplaces"][1] == 2048


def test_undecodable_bytes_raise_invalid_image():
    import pytest

    from app.embedding import InvalidImageError, load_and_resize, load_keep_aspect

    for loader in (lambda b: load_and_resize(b), lambda b: load_keep_aspect(b, 384)):
        with pytest.raises(InvalidImageError):
            loader(b"definitely not an image")
        with pytest.raises(InvalidImageError):
            loader(b"")
