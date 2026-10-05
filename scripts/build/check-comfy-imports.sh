#!/usr/bin/env bash
# check-comfy-imports: start ComfyUI once on the CPU and fail the build if it does
# not start cleanly or a custom node cannot be imported.
#
# Environment:
#   COMFY_IMPORT_ALLOW_FAILED  space-separated custom_nodes folder names that may
#                              fail to import here, for nodes that cannot be
#                              imported without a GPU. Leave empty otherwise.
set -uo pipefail

log=/tmp/comfy-imports.log
allowed=" ${COMFY_IMPORT_ALLOW_FAILED:-} "
cd "${COMFYUI_PATH:-/comfyui}"

status=0
/opt/venv/bin/python main.py --cpu --quick-test-for-ci --disable-auto-launch > "$log" 2>&1 || status=$?

problems=()
if [[ $status -ne 0 ]]; then
  problems+=("ComfyUI exited with status $status")
fi
if ! grep -q "Import times for custom nodes" "$log"; then
  problems+=("ComfyUI did not reach the custom-node import summary")
fi
while IFS= read -r node; do
  [[ -z "$node" ]] && continue
  if [[ "$allowed" == *" $node "* ]]; then
    echo "check-comfy-imports: $node failed to import and is on the allow list (it needs a GPU)"
  else
    problems+=("custom node $node failed to import")
  fi
done < <(grep -F "(IMPORT FAILED)" "$log" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's#.*/custom_nodes/##' -e 's/[[:space:]]*$//')

if [[ ${#problems[@]} -gt 0 ]]; then
  cat "$log"
  echo >&2
  for p in "${problems[@]}"; do echo "check-comfy-imports: $p" >&2; done
  exit 1
fi

grep -E "[0-9.]+ seconds( \(IMPORT FAILED\))?: " "$log" | sed 's/\x1b\[[0-9;]*m//g' || true
rm -f "$log" user/comfyui*.log
echo "check-comfy-imports OK"
