"""Test image uploads without starting the RunPod worker or loading GPU dependencies."""
import ast
import base64
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock


class ImageInputTests(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[1] / "handler.py"
        tree = ast.parse(source.read_text(encoding="utf-8"))
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                        and node.name == "upload_images")
        self.requests = SimpleNamespace(get=MagicMock(), post=MagicMock(),
                                        Timeout=TimeoutError, RequestException=ConnectionError)
        scope = dict(requests=self.requests, base64=base64, BytesIO=BytesIO,
                     COMFY_HOST="localhost:8188")
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec"), scope)
        self.upload = scope["upload_images"]

    def download(self, content_type="image/jpeg", chunks=(b"image bytes",)):
        response = self.requests.get.return_value.__enter__.return_value
        response.headers = {"Content-Type": content_type}
        response.iter_content.return_value = iter(chunks)
        return response

    def test_url_download_and_upload(self):
        self.download()
        result = self.upload([{"name": "photo.jpg", "image": "https://example.com/image?signature=abc"}])
        self.assertEqual(result["status"], "success")
        self.requests.get.assert_called_once_with("https://example.com/image?signature=abc",
                                                  stream=True, timeout=(10, 60))
        name, stream, mime = self.requests.post.call_args.kwargs["files"]["image"]
        self.assertEqual((name, stream.getvalue(), mime), ("photo.jpg", b"image bytes", "image/jpeg"))

    def test_base64_and_data_uri(self):
        encoded = base64.b64encode(b"image bytes").decode()
        for value in (encoded, "data:image/png;base64," + encoded):
            with self.subTest(value=value):
                self.assertEqual(self.upload([{"name": "image.png", "image": value}])["status"], "success")
                self.assertEqual(self.requests.post.call_args.kwargs["files"]["image"][1].getvalue(), b"image bytes")
        self.requests.get.assert_not_called()

    def test_invalid_downloads_are_not_uploaded(self):
        for content_type, chunks in (("text/html", (b"html",)), ("image/png", ()),
                                     ("image/png", (b"x" * (50 * 1024 * 1024 + 1),))):
            with self.subTest(content_type=content_type, size=sum(map(len, chunks))):
                self.download(content_type, chunks)
                result = self.upload([{"name": "image.png", "image": "http://example.com/image"}])
                self.assertEqual(result["status"], "error")
                self.requests.post.assert_not_called()

    def test_http_error_and_timeout(self):
        response = self.download()
        response.raise_for_status.side_effect = ConnectionError("HTTP 404")
        self.assertEqual(self.upload([{"name": "image.png", "image": "https://example.com/image"}])["status"], "error")
        self.requests.get.side_effect = TimeoutError()
        self.assertEqual(self.upload([{"name": "image.png", "image": "https://example.com/image"}])["status"], "error")
        self.requests.post.assert_not_called()


if __name__ == "__main__":
    unittest.main()
