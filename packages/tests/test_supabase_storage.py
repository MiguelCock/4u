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


def test_upload_image_sets_content_type_from_filename():
    db = _make_supabase()
    fake_file = BytesIO(b"fake-image-bytes")

    db.upload_image("anchor-points", fake_file, "photo.jpg")

    upload_mock = db.client.storage.from_.return_value.upload
    assert upload_mock.call_args.kwargs["file_options"] == {
        "content-type": "image/jpeg"
    }


def test_upload_image_falls_back_to_octet_stream_for_unknown_extension():
    db = _make_supabase()
    fake_file = BytesIO(b"fake-bytes")

    db.upload_image("anchor-points", fake_file, "photo.unknownext")

    upload_mock = db.client.storage.from_.return_value.upload
    assert upload_mock.call_args.kwargs["file_options"] == {
        "content-type": "application/octet-stream"
    }


def test_delete_images_by_url_extracts_filenames_and_removes_in_one_call():
    db = _make_supabase()
    urls = [
        "https://x.supabase.co/storage/v1/object/public/anchor-points/a.jpg",
        "https://x.supabase.co/storage/v1/object/public/anchor-points/b.jpg",
    ]

    db.delete_images_by_url("anchor-points", urls)

    db.client.storage.from_.assert_called_once_with("anchor-points")
    remove_mock = db.client.storage.from_.return_value.remove
    remove_mock.assert_called_once_with(["a.jpg", "b.jpg"])


def test_delete_images_by_url_skips_storage_call_when_no_urls():
    db = _make_supabase()

    db.delete_images_by_url("anchor-points", [])

    db.client.storage.from_.return_value.remove.assert_not_called()


def test_post_photos_passes_bytes_not_the_raw_file_object():
    db = _make_supabase()
    fake_file = BytesIO(b"fake-photo-bytes")
    fake_file.name = "photo.jpg"

    db.post_photos(fake_file, 6.24, -75.58, 8.5)

    upload_mock = db.client.storage.from_.return_value.upload
    upload_mock.assert_called_once()
    assert upload_mock.call_args.kwargs["file"] == b"fake-photo-bytes"
