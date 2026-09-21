import cv2
import numpy as np

from app.embedding import load_and_resize


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
