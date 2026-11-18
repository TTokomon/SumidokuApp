"""Exercise media negotiation and bounded download failures without network access."""

import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common


class DownloadTests(unittest.TestCase):
    def transfer(self, endpoint_kind, destination, payload, status=0, limit=16):
        if endpoint_kind == "actions":
            endpoint = f"repos/{common.REPO}/actions/artifacts/42/zip"
            accept = "application/vnd.github+json"
        else:
            endpoint = f"repos/{common.REPO}/releases/assets/42"
            accept = "application/octet-stream"

        def request(args, **kwargs):
            self.assertEqual(args[:4], ["gh", "api", endpoint, "-H"])
            correct = args[4] == f"Accept: {accept}"
            if not correct and endpoint_kind == "release":
                # A JSON request can succeed with metadata instead of bytes.
                return Mock(stdout=io.BytesIO(b'{"id":42}'), wait=Mock(return_value=0), poll=Mock(return_value=0))
            result = status if correct else 1  # gh exits non-zero on HTTP 415
            return Mock(stdout=io.BytesIO(payload if correct else b""), wait=Mock(return_value=result), poll=Mock(return_value=result))

        with patch.object(common.subprocess, "Popen", side_effect=request):
            if endpoint_kind == "actions":
                common.download_stream(endpoint, destination, limit)
            else:
                asset = {"id": 42, "size": 4, "digest": "sha256:" + hashlib.sha256(b"data").hexdigest()}
                common.download_asset(asset, destination, limit)

    def test_actions_zip_and_release_assets_negotiate_their_own_media_types(self):
        for kind in ("actions", "release"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                destination = Path(tmp) / "download"
                try:
                    self.transfer(kind, destination, b"data")
                except ValueError as error:
                    self.fail(f"{kind} endpoint did not return its bytes: {error}")
                self.assertEqual(destination.read_bytes(), b"data")

    def test_both_paths_reject_failed_or_oversized_streams(self):
        for kind in ("actions", "release"):
            for payload, status, error in (
                (b"da", 1, "Incomplete artifact download"),
                (b"", 1, "Incomplete artifact download"),
                (b"data" * 5, 0, "Download exceeded its size bound"),
            ):
                with self.subTest(kind=kind, error=error), tempfile.TemporaryDirectory() as tmp:
                    self.assertRaisesRegex(ValueError, error, self.transfer, kind, Path(tmp) / "download", payload, status)

    def test_release_assets_reject_short_success_and_wrong_bytes(self):
        for payload, error in ((b"da", "Incomplete artifact download"), (b"json", "asset digest mismatch")):
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as tmp:
                self.assertRaisesRegex(ValueError, error, self.transfer, "release", Path(tmp) / "download", payload)
