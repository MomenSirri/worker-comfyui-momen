"""A signed link is a credential: neither the worker's log nor a job's answer may hold one."""

import contextlib
import io
import json
import os
import subprocess
import sys
import unittest
from unittest.mock import MagicMock, patch

# Make sure the repository root is known and can be used to import handler.py
REPOSITORY_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.append(REPOSITORY_DIR)
sys.path.append(os.path.join(REPOSITORY_DIR, "src"))
import handler

SIGNATURE = "secret-signature"
PROVIDER_LINK = f"https://cdn.example.com/results/clip.mp4?X-Amz-Signature={SIGNATURE}&X-Amz-Expires=604800"
RESULT_LINK = f"https://bucket.example.com/10-26/job-1/ComfyUI_00001_.png?X-Amz-Signature={SIGNATURE}"
PROMPT_ID = "prompt-1"
WORKFLOW = {"9": {"class_type": "SaveImage", "inputs": {"filename_prefix": "ComfyUI"}}}
SAVED_IMAGE = {
    PROMPT_ID: {
        "outputs": {
            "9": {"images": [{"filename": "ComfyUI_00001_.png", "subfolder": "", "type": "output"}]}
        }
    }
}
FINISHED = {"type": "executing", "data": {"prompt_id": PROMPT_ID, "node": None}}

# Imports the handler first, as the worker does, then asks the SDK for its level.
SDK_LOG_LEVEL_PROBE = """
import importlib.util
import sys

sys.path[:0] = sys.argv[1:]
if importlib.util.find_spec("runpod") is None:
    sys.exit(3)

import handler
from runpod.serverless.modules.rp_logger import RunPodLogger

print(RunPodLogger.level)
"""


class TestRunpodLogLevel(unittest.TestCase):
    """At DEBUG the RunPod SDK logs the handler's whole output, signed result links included."""

    def sdk_log_level(self, **variables):
        environment = {
            name: value
            for name, value in os.environ.items()
            if name not in ("RUNPOD_LOG_LEVEL", "RUNPOD_DEBUG_LEVEL")
        }
        probe = subprocess.run(
            [sys.executable, "-c", SDK_LOG_LEVEL_PROBE, REPOSITORY_DIR, os.path.join(REPOSITORY_DIR, "src")],
            env={**environment, **variables},
            capture_output=True,
            text=True,
            timeout=120,
        )
        if probe.returncode == 3:
            self.skipTest("the RunPod SDK is not installed")
        self.assertEqual(probe.returncode, 0, probe.stderr)
        return probe.stdout.split()[-1]

    def test_sdk_logs_at_info_when_no_level_is_set(self):
        self.assertEqual(self.sdk_log_level(), "INFO")

    def test_endpoint_can_still_set_debug(self):
        self.assertEqual(self.sdk_log_level(RUNPOD_LOG_LEVEL="DEBUG"), "DEBUG")

    def test_older_variable_alone_does_not_lower_the_level(self):
        self.assertEqual(self.sdk_log_level(RUNPOD_DEBUG_LEVEL="DEBUG"), "INFO")

    def test_blank_level_counts_as_not_set(self):
        # The SDK raises on a blank level while it is imported.
        self.assertEqual(self.sdk_log_level(RUNPOD_LOG_LEVEL=""), "INFO")


class TestQueryStringCut(unittest.TestCase):
    def test_query_strings_are_cut_in_the_forms_http_clients_report(self):
        reports = {
            "aiohttp": "400, message='Bad status line', url='https://cdn.example.com/a.mp4?sig=secret-signature&se=1'",
            "requests": "403 Client Error: Forbidden for url: https://cdn.example.com/a.mp4?token=secret-signature",
            "urllib3": "Max retries exceeded with url: /a.mp4?X-Amz-Signature=secret-signature (Caused by Timeout)",
            "json": '{"url":"https://cdn.example.com/a.mp4?sig=secret-signature","error":"quota exceeded"}',
            # A URL may hold a single quote, so the cut must not end at one.
            "quote in the query": "403, message='Forbidden', url=\"https://cdn.example.com/a.mp4?name=it's&sig=secret-signature\"",
            "no parameter name": "404, message='Not Found', url='https://cdn.example.com/a.mp4?secret-signature'",
        }

        for client, report in reports.items():
            with self.subTest(client=client):
                redacted = handler._redact_url_queries(report)

                self.assertIn("a.mp4?[redacted]", redacted)
                self.assertNotIn(SIGNATURE, redacted)

        self.assertIn('"error":"quota exceeded"', handler._redact_url_queries(reports["json"]))

    def test_text_without_a_query_string_is_left_alone(self):
        messages = (
            "Value not in list: ckpt_name: 'a.safetensors' not in ['b']. Did you mean b? Set x=1.",
            "Pattern (?=abc) did not match, see https://docs.example.com/errors#e1203",
        )

        for message in messages:
            with self.subTest(message=message):
                self.assertEqual(handler._redact_url_queries(message), message)


class TestJobKeepsLinksSecret(unittest.TestCase):
    """Whole jobs against a ComfyUI that is replaced at the handler's own calls."""

    def run_job(self, messages, history=None, upload=None, fail_fast=True):
        """Return a job's answer and everything it logged or reported as progress."""
        socket = MagicMock(connected=False)
        socket.recv.side_effect = [json.dumps(message) for message in messages]
        progress = MagicMock()
        log = io.StringIO()
        replaced = (
            patch.object(handler, "check_server", return_value=True),
            patch.object(handler, "queue_workflow", return_value={"prompt_id": PROMPT_ID}),
            patch.object(handler.websocket, "WebSocket", return_value=socket),
            patch.object(handler, "_emit_seedvr_runtime_logs"),
            patch.object(handler, "get_history", return_value=history or {PROMPT_ID: {"outputs": {}}}),
            patch.object(handler, "get_image_data", return_value=b"png bytes"),
            patch.object(handler.rp_upload, "upload_image", side_effect=upload),
            patch.object(handler.runpod.serverless, "progress_update", progress),
            patch.object(handler, "FAIL_FAST_ON_EXECUTION_ERROR", fail_fast),
            patch.dict(os.environ, {"BUCKET_ENDPOINT_URL": "https://s3.example.com"}),
            contextlib.redirect_stdout(log),
        )
        with contextlib.ExitStack() as stack:
            for replacement in replaced:
                stack.enter_context(replacement)
            result = handler.handler({"id": "job-1", "input": {"workflow": WORKFLOW}})
        reported = "\n".join(str(call.args[1]) for call in progress.call_args_list)
        return result, log.getvalue() + reported

    def test_failed_node_does_not_expose_the_link_in_its_message(self):
        # HTTP clients end their error text with the request URL.
        failed_node = {
            "type": "execution_error",
            "data": {
                "prompt_id": PROMPT_ID,
                "node_id": "8",
                "node_type": "ProviderNode",
                "exception_message": f"402, message='Payment Required', url='{PROVIDER_LINK}'",
            },
        }

        for fail_fast in (True, False):
            with self.subTest(fail_fast=fail_fast):
                result, logged = self.run_job([failed_node], fail_fast=fail_fast)

                answer = json.dumps(result)
                self.assertIn("error", result)
                self.assertIn("Payment Required", answer)
                self.assertIn("cdn.example.com/results/clip.mp4?[redacted]", answer)
                self.assertIn("cdn.example.com/results/clip.mp4?[redacted]", logged)
                self.assertNotIn(SIGNATURE, answer)
                self.assertNotIn(SIGNATURE, logged)

    def test_failed_upload_does_not_expose_a_link(self):
        refused = RuntimeError(f"403 Client Error: Forbidden for url: {RESULT_LINK}")

        result, logged = self.run_job([FINISHED], history=SAVED_IMAGE, upload=refused)

        answer = json.dumps(result)
        self.assertIn("error", result)
        self.assertIn("Error uploading ComfyUI_00001_.png to S3", answer)
        self.assertNotIn(SIGNATURE, answer)
        self.assertNotIn(SIGNATURE, logged)

    def test_upload_is_logged_without_its_signature(self):
        result, logged = self.run_job([FINISHED], history=SAVED_IMAGE, upload=[RESULT_LINK])

        # The caller needs the whole link; the log only says where the object is.
        self.assertEqual(result["images"][0]["data"], RESULT_LINK)
        self.assertIn("Uploaded ComfyUI_00001_.png to S3: https://bucket.example.com/10-26/job-1/", logged)
        self.assertNotIn(SIGNATURE, logged)


if __name__ == "__main__":
    unittest.main()
