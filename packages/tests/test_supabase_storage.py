from io import BytesIO
from unittest.mock import MagicMock

from packages.supabase import SupaBase


def _make_supabase() -> SupaBase:
    # Bypass __init__ (and its eager create_client URL validation) - these
    # tests only exercise how upload_image/post_photos call self.client.
    db = SupaBase.__new__(SupaBase)
    db.client = MagicMock()
    return db


def test_upload_image_passes_bytes_not_the_raw_file_object():
    db = _make_supabase()
    fake_file = BytesIO(b"fake-image-bytes")

    db.upload_image("anchor-points", fake_file, "photo.jpg")

    upload_mock = db.client.storage.from_.return_value.upload
    upload_mock.assert_called_once()
    assert upload_mock.call_args.kwargs["file"] == b"fake-image-bytes"


def test_post_photos_passes_bytes_not_the_raw_file_object():
    db = _make_supabase()
    fake_file = BytesIO(b"fake-photo-bytes")
    fake_file.name = "photo.jpg"

    db.post_photos(fake_file, 6.24, -75.58, 8.5)

    upload_mock = db.client.storage.from_.return_value.upload
    upload_mock.assert_called_once()
    assert upload_mock.call_args.kwargs["file"] == b"fake-photo-bytes"
