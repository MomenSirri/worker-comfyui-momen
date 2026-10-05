# CI/CD

## What runs automatically

[`ci.yml`](../.github/workflows/ci.yml) runs on every push, on a standard GitHub runner, in a few minutes. It needs no GPU, no models and no secrets:

- the Python unit tests (`tests/`) and the snapshot restore script test;
- a syntax check of every shell script and build helper;
- Docker's Dockerfile checks (`docker buildx build --check .`);
- `docker buildx bake --print` for every target, so a broken Bake file fails here;
- the format of the model checksum lists.

Its first run, on 2026-10-05, passed every step ([run 37358008640](https://github.com/MomenSirri/worker-comfyui-momen/actions/runs/37358008640)).

Run the same checks locally:

```bash
python -m pip install -r requirements.txt
python -m unittest discover -s tests -p "test_*.py"
docker buildx build --check .
docker buildx bake -f docker-bake.hcl --print enhance seedvr
```

## What does not run automatically

Images are built and pushed by hand, with the commands in [command.txt](../command.txt) and [README-General-Enhancement.md](../README-General-Enhancement.md). Each image is 30 GB or more and needs more disk than a hosted runner has.

The upstream project's release workflows were removed from this fork on 2026-10-05. They targeted runners this repository does not have, published under another image name, and had never run here.

## Before publishing an image

1. Choose a tag that does not exist on Docker Hub yet. A push to an existing tag replaces it, and an endpoint that uses that tag changes with it.
2. Commit and push the source first, so the published image can be traced to a commit. [published-images.md](published-images.md) records what happened when that was skipped.
3. After the build, record the image digest and `pip freeze` next to the workflow, as `workflows/general-enhancement/pip-freeze-v07.txt` does.
