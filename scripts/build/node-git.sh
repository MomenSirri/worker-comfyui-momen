#!/usr/bin/env bash
# node-git: install a custom node from Git at one exact revision.
#
# Usage: node-git.sh <folder> <repository-url> <ref>
#
# <ref> is a commit hash, a tag or a branch name. Only that revision is
# fetched. The node's requirements.txt is installed into /opt/venv when present.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: node-git.sh <folder> <repository-url> <ref>" >&2
  exit 64
fi

name="$1"
repo="$2"
ref="$3"
dest="${COMFYUI_PATH:-/comfyui}/custom_nodes/${name}"

rm -rf "$dest"
mkdir -p "$dest"
git init -q "$dest"
git -C "$dest" remote add origin "$repo"
git -C "$dest" fetch -q --depth 1 origin "$ref"
git -C "$dest" -c advice.detachedHead=false checkout -q FETCH_HEAD
echo "node-git: ${name} at $(git -C "$dest" rev-parse HEAD) (${ref})"

if [[ -f "$dest/requirements.txt" ]]; then
  /opt/venv/bin/python -m pip install --no-cache-dir -r "$dest/requirements.txt"
fi
