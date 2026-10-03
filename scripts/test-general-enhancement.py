"""Prepare and validate the General Enhancement API payload; optionally run it."""
import argparse
import base64
import copy
import json
from pathlib import Path
import urllib.error
import urllib.request


def fetch_json(url, payload=None, timeout=60):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", help="Local image file or HTTP(S) image URL")
    parser.add_argument("--comfy-url", default="http://127.0.0.1:8188")
    parser.add_argument("--worker-url", default="http://127.0.0.1:8000")
    parser.add_argument("--int4", action="store_true", help="Select Fluxmania INT4 for non-Blackwell GPUs")
    parser.add_argument("--without-embeddings", action="store_true", help="Remove the two missing embedding references; changes conditioning")
    parser.add_argument("--payload", default="general-enhancement-input.json")
    parser.add_argument("--run", action="store_true", help="Submit /runsync after validation")
    parser.add_argument("--timeout", type=int, default=3600, help="HTTP timeout for workflow execution")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    workflow = copy.deepcopy(json.loads((root / "workflows/general-enhancement/workflow_api_flux_dev_1.19.json").read_text(encoding="utf-8")))
    if args.image.lower().startswith(("http://", "https://")):
        image = args.image
        filename = "enhancement-input.png"
    else:
        path = Path(args.image)
        image = base64.b64encode(path.read_bytes()).decode()
        filename = "enhancement-input" + path.suffix.lower()
    workflow["81"]["inputs"]["image"] = filename
    if args.int4:
        workflow["40"]["inputs"]["model_path"] = "svdq-int4_r32-fluxmania-legacy.safetensors"
    if args.without_embeddings:
        workflow["27"]["inputs"]["text"] = workflow["27"]["inputs"]["text"].replace("embedding:easynegative,", "").replace("embedding:epiCNegative,", "")
    payload = {"input": {"workflow": workflow, "images": [{"name": filename, "image": image}]}}
    Path(args.payload).write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"Wrote {args.payload}")
    info = fetch_json(args.comfy_url.rstrip("/") + "/object_info")
    errors = []
    for node_id, node in workflow.items():
        class_type = node["class_type"]
        if class_type not in info:
            errors.append(f"Node {node_id}: missing class {class_type}")
            continue
        schema = info[class_type].get("input", {})
        for group in ("required", "optional"):
            for name, definition in schema.get(group, {}).items():
                value = node["inputs"].get(name)
                if isinstance(value, (str, int, float, bool)) and definition and isinstance(definition[0], list):
                    if value not in definition[0]:
                        errors.append(f"Node {node_id} ({class_type}): {name}={value!r} is unavailable")
        for name, definition in schema.get("required", {}).items():
            if name not in node["inputs"]:
                errors.append(f"Node {node_id} ({class_type}): missing required input {name}")
    if errors:
        raise SystemExit("Workflow preflight failed:\n" + "\n".join(errors))
    print("All workflow node classes, required inputs, and literal dropdown values are available.")
    print("This preflight does not test GPU inference, embeddings, projector files, or linked value types.")
    if args.run:
        response = fetch_json(args.worker_url.rstrip("/") + "/runsync", payload, args.timeout)
        Path("general-enhancement-result.json").write_text(json.dumps(response, indent=2), encoding="utf-8")
        print("Saved response to general-enhancement-result.json")
        output = response.get("output", {})
        print("Job status:", response.get("status"), "Worker status:", output.get("status") if isinstance(output, dict) else None)
        if not isinstance(output, dict) or output.get("status") != "success":
            raise SystemExit("Job did not return worker success; inspect the result file and container logs.")
        print("Returned images:", len(output.get("message", [])))


if __name__ == "__main__":
    try:
        main()
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise SystemExit(str(error))
