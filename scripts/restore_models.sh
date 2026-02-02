#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

echo "Starting model restoration..."

: "${COMFYUI_BACKUP:?set COMFYUI_BACKUP to HF repo id (e.g. user/my-backup)}"

# Quieter tooling
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONWARNINGS=ignore

COMFY="/workspace/ComfyUI"
DEST="$COMFY/models"
TMP="/workspace/.backup_tmp/hf_models"
HFHOME="${HF_HOME:-/workspace/.hf}"

mkdir -p "$DEST" "$(dirname "$TMP")" "$HFHOME"
export HF_HOME="$HFHOME"

# Preflight: skip everything if repo doesn't exist / not accessible
PYTHONWARNINGS=ignore python - <<'PY'
import os, sys
from huggingface_hub import HfApi
from huggingface_hub.errors import RepositoryNotFoundError, HfHubHTTPError

repo = os.environ["COMFYUI_BACKUP"]
api = HfApi()
ok = False
for t in ("model", "dataset"):
    try:
        api.repo_info(repo_id=repo, repo_type=t)
        ok = True
        break
    except RepositoryNotFoundError:
        pass
    except HfHubHTTPError:
        # 401/403 etc. -> treat as not accessible for startup; skip
        pass

if not ok:
    print(f"[models] Backup repo '{repo}' not accessible; skipping model restore.")
    sys.exit(0)
PY

PYTHONWARNINGS=ignore python - <<'PY'
import os, shutil, sys
from huggingface_hub import snapshot_download

repo  = os.environ["COMFYUI_BACKUP"]
dest  = "/workspace/ComfyUI/models"
local = "/workspace/.backup_tmp/hf_models"

if os.path.isdir(local):
    shutil.rmtree(local)

try:
    snapshot_download(
        repo_id=repo,
        local_dir=local,
        local_dir_use_symlinks=False,
        resume_download=True,
        allow_patterns=["ComfyUI/models/**"],
    )
except Exception as e:
    # Any error from the hub (404/401/403/etc) should result in skipping model restore.
    # Print a short, helpful message and exit without a traceback.
    print(f"[models] snapshot download failed or repo not accessible: {e}; skipping model restore.")
    sys.exit(0)

src = os.path.join(local, "ComfyUI", "models")
if os.path.isdir(src):
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        outdir = os.path.join(dest, rel) if rel != "." else dest
        os.makedirs(outdir, exist_ok=True)
        for f in files:
            s = os.path.join(root, f)
            d = os.path.join(outdir, f)
            if os.path.exists(d) and not os.path.islink(d):
                try: os.remove(d)
                except: pass
            shutil.copy2(s, d)
            print(f"[models] {os.path.join(rel, f)}")
else:
    print("[models] nothing to restore (no ComfyUI/models in repo)")
PY

echo "[models] done."
