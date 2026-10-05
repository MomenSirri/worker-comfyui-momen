import unittest
from unittest.mock import patch, MagicMock
import sys
import os
import json
import base64

# Make sure the repository root is known and can be used to import handler.py
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src")))
import handler

# Local folder for test resources
RUNPOD_WORKER_COMFY_TEST_RESOURCES_IMAGES = "./test_resources/images"


class TestRunpodWorkerComfy(unittest.TestCase):
    def test_finalize_job_result_success_with_images(self):
        images = [
            {"data": "img1", "filename": "ComfyUI_00001_.png", "type": "base64"},
            {"data": "img2", "filename": "ComfyUI_00002_.png", "type": "base64"},
        ]

        result = handler._finalize_job_result(images)

        self.assertEqual(result, {"images": images})

    def test_finalize_job_result_fails_when_no_images(self):
        result = handler._finalize_job_result([], warnings=["Node 55 produced unhandled output keys: ['text']."])
        self.assertIn("error", result)
        self.assertEqual(result["error"], "Workflow produced no images.")
        self.assertIn("details", result)
        self.assertTrue(any("unhandled output keys" in item for item in result["details"]))
        self.assertTrue(result.get("refresh_worker"))

    def test_valid_input_with_workflow_only(self):
        input_data = {"workflow": {"key": "value"}}
        validated_data, error = handler.validate_input(input_data)
        self.assertIsNone(error)
        self.assertEqual(
            validated_data,
            {"workflow": {"key": "value"}, "images": None, "comfy_org_api_key": None},
        )

    def test_valid_input_with_workflow_and_images(self):
        input_data = {
            "workflow": {"key": "value"},
            "images": [{"name": "image1.png", "image": "base64string"}],
        }
        validated_data, error = handler.validate_input(input_data)
        self.assertIsNone(error)
        self.assertEqual(
            validated_data,
            {
                "workflow": {"key": "value"},
                "images": [{"name": "image1.png", "image": "base64string"}],
                "comfy_org_api_key": None,
            },
        )

    def test_input_missing_workflow(self):
        input_data = {"images": [{"name": "image1.png", "image": "base64string"}]}
        validated_data, error = handler.validate_input(input_data)
        self.assertIsNotNone(error)
        self.assertEqual(error, "Missing 'workflow' parameter")

    def test_input_with_invalid_images_structure(self):
        input_data = {
            "workflow": {"key": "value"},
            "images": [{"name": "image1.png"}],  # Missing 'image' key
        }
        validated_data, error = handler.validate_input(input_data)
        self.assertIsNotNone(error)
        self.assertEqual(
            error, "'images' must be a list of objects with 'name' and 'image' keys"
        )

    def test_invalid_json_string_input(self):
        input_data = "invalid json"
        validated_data, error = handler.validate_input(input_data)
        self.assertIsNotNone(error)
        self.assertEqual(error, "Invalid JSON format in input")

    def test_valid_json_string_input(self):
        input_data = '{"workflow": {"key": "value"}}'
        validated_data, error = handler.validate_input(input_data)
        self.assertIsNone(error)
        self.assertEqual(
            validated_data,
            {"workflow": {"key": "value"}, "images": None, "comfy_org_api_key": None},
        )

    def test_empty_input(self):
        input_data = None
        validated_data, error = handler.validate_input(input_data)
        self.assertIsNotNone(error)
        self.assertEqual(error, "Please provide input")

    @patch("handler.requests.get")
    def test_check_server_server_up(self, mock_requests):
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_requests.return_value = mock_response

        result = handler.check_server("http://127.0.0.1:8188", 1, 50)
        self.assertTrue(result)

    @patch("handler.requests.get")
    def test_check_server_server_down(self, mock_requests):
        mock_requests.side_effect = handler.requests.RequestException()
        result = handler.check_server("http://127.0.0.1:8188", 1, 50)
        self.assertFalse(result)

    @patch("handler.requests.post")
    def test_queue_prompt(self, mock_post):
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {"prompt_id": "123"}
        mock_post.return_value = mock_response

        result = handler.queue_workflow({"prompt": "test"}, "client-123")

        self.assertEqual(result, {"prompt_id": "123"})

    @patch("handler.requests.get")
    def test_get_history(self, mock_get):
        mock_response = MagicMock()
        mock_response.json.return_value = {"key": "value"}
        mock_get.return_value = mock_response

        result = handler.get_history("123")

        self.assertEqual(result, {"key": "value"})
        mock_get.assert_called_once_with("http://127.0.0.1:8188/history/123", timeout=30)

    @patch("handler.requests.post")
    def test_upload_images_successful(self, mock_post):
        mock_response = unittest.mock.Mock()
        mock_response.status_code = 200
        mock_response.text = "Successfully uploaded"
        mock_post.return_value = mock_response

        test_image_data = base64.b64encode(b"Test Image Data").decode("utf-8")

        images = [{"name": "test_image.png", "image": test_image_data}]

        responses = handler.upload_images(images)

        self.assertEqual(len(responses), 3)
        self.assertEqual(responses["status"], "success")

    @patch("handler.requests.post")
    def test_upload_images_failed(self, mock_post):
        mock_response = unittest.mock.Mock()
        mock_response.status_code = 400
        mock_response.text = "Error uploading"
        mock_response.raise_for_status.side_effect = handler.requests.RequestException(
            "Error uploading"
        )
        mock_post.return_value = mock_response

        test_image_data = base64.b64encode(b"Test Image Data").decode("utf-8")

        images = [{"name": "test_image.png", "image": test_image_data}]

        responses = handler.upload_images(images)

        self.assertEqual(len(responses), 3)
        self.assertEqual(responses["status"], "error")
