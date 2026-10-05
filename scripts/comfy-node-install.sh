#!/usr/bin/env bash
# comfy-node-install: install custom ComfyUI nodes from the registry and fail with
# a non-zero exit code if any of them cannot be installed. On failure it prints the
# list of nodes that could not be installed and hints the user to consult
# https://registry.comfy.org/ for correct names.
#
# A node can be given as <name> or as <name>@<version>. After the installation
# every requested node must exist under custom_nodes, at the requested version
# when one was given: the installer itself exits with 0 for a version that does
# not exist.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: comfy-node-install <node1>[@<version>] [<node2>[@<version>] …]" >&2
  exit 64  # EX_USAGE
fi

log=$(mktemp)
nodes_dir="${COMFYUI_PATH:-/comfyui}/custom_nodes"

# run installation – some modes return non-zero even on success, so we
# ignore the exit status and rely on log parsing instead. The time limit turns
# a hanging installer into a failed build.
set +e
timeout "${COMFY_NODE_INSTALL_TIMEOUT:-3600}" comfy node install --mode=remote "$@" 2>&1 | tee "$log"
cli_status=$?
set -e

if [[ $cli_status -eq 124 ]]; then
  echo "comfy node install did not finish within ${COMFY_NODE_INSTALL_TIMEOUT:-3600} seconds." >&2
  exit 1
fi

# extract node names that failed to install (one per line, uniq-sorted)
failed_nodes=$(grep -oP "(?<=An error occurred while installing ')[^']+" "$log" | sort -u || true)

# Fallback: capture names from "Node '<name>@' not found" lines if previous grep found nothing
if [[ -z "$failed_nodes" ]]; then
  failed_nodes=$(grep -oP "(?<=Node ')[^@']+" "$log" | sort -u || true)
fi

if [[ -n "$failed_nodes" ]]; then
  echo "Comfy node installation failed for the following nodes:" >&2
  echo "$failed_nodes" | while read -r n; do echo "  • $n" >&2 ; done
  echo >&2
  echo "Please verify the node names at https://registry.comfy.org/ and try again." >&2
  exit 1
fi

# verify the result on disk
problems=()
for spec in "$@"; do
  name="${spec%@*}"
  version=""
  if [[ "$spec" == *@* ]]; then version="${spec##*@}"; fi

  dir=$(find "$nodes_dir" -mindepth 1 -maxdepth 1 -type d -iname "$name" | head -n 1)
  if [[ -z "$dir" ]]; then
    problems+=("$spec: not found in $nodes_dir")
    continue
  fi

  # only numbered versions can be compared; "latest" and "nightly" cannot
  if [[ "$version" =~ ^[0-9] ]]; then
    actual=$(sed -n 's/^version *= *"\(.*\)".*/\1/p' "$dir/pyproject.toml" 2>/dev/null | head -n 1)
    if [[ "$actual" != "$version" ]]; then
      problems+=("$spec: version ${actual:-unknown} is installed")
    fi
  fi
done

if [[ ${#problems[@]} -gt 0 ]]; then
  echo "Comfy node installation did not produce the requested nodes:" >&2
  for p in "${problems[@]}"; do echo "  • $p" >&2 ; done
  echo >&2
  echo "Please verify the node names and versions at https://registry.comfy.org/ and try again." >&2
  exit 1
fi

# If we reach here no failed nodes were detected. Warn if CLI exit status
# was non-zero but treat it as success.
if [[ $cli_status -ne 0 ]]; then
  echo "Warning: comfy node install exited with status $cli_status but no errors were detected in the log — assuming success." >&2
fi

exit 0
