#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

COMFY="/workspace/ComfyUI"
TMP="/workspace/.backup_tmp"
HFHOME="${HF_HOME:-/workspace/.hf}"

mkdir -p "$TMP" "$COMFY/user/default" "$COMFY/custom_nodes" "$HFHOME"
export HF_HOME="$HFHOME"

: "${COMFYUI_BACKUP:?set COMFYUI_BACKUP to HF repo id (e.g. user/my-backup)}"

# Preflight: skip everything if repo doesn't exist / not accessible
python - <<'PY'
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
    print(f"[restore] Backup repo '{repo}' not accessible; skipping nodes/settings restore.")
    sys.exit(0)
PY

echo "STAGE: Preparing ComfyUI Manager"
MANAGER_PREFETCH_LOG="$TMP/manager_prefetch.log"
if command -v comfy >/dev/null 2>&1; then
    if (cd "$COMFY" && comfy --here --skip-prompt node show snapshot-list --mode remote >"$MANAGER_PREFETCH_LOG" 2>&1); then
        echo "[restore] ComfyUI-Manager cache warmed (snapshot-list --mode remote)"
    else
        echo "[restore][warn] failed to warm ComfyUI-Manager cache (non-blocking); see $MANAGER_PREFETCH_LOG"
    fi
else
    echo "[restore][warn] comfy CLI not found; skipping ComfyUI-Manager prep"
fi

echo "STAGE: Installing nodes from backup"

python - "$COMFY" "$TMP" <<'PY'
import os, shutil, sys, shlex, subprocess
from huggingface_hub import snapshot_download

comfy, tmp = sys.argv[1], sys.argv[2]
repo = os.environ["COMFYUI_BACKUP"]

local = os.path.join(tmp, "hf_pull")
if os.path.isdir(local):
    shutil.rmtree(local)

# Pull only snapshot + settings + workflows
try:
    snapshot_download(
        repo_id=repo,
        local_dir=local,
        local_dir_use_symlinks=False,
        resume_download=True,
        allow_patterns=[
            "ComfyUI/custom_nodes_snapshot.yaml",
            "ComfyUI/user/default/comfy.settings.json",
            # workflows can be stored in either location depending on backup
            "ComfyUI/user/default/workflows/**",
            "ComfyUI/user/workflows/**",
            # subgraphs commonly under default, but support both
            "ComfyUI/user/default/subgraphs/**",
            "ComfyUI/user/subgraphs/**",
        ],
    )
except Exception as e:
    print(f"[restore] snapshot download failed or repo not accessible: {e}; skipping nodes/settings restore.")
    sys.exit(0)

snap = os.path.join(local, "ComfyUI", "custom_nodes_snapshot.yaml")
settings_src = os.path.join(local, "ComfyUI", "user", "default", "comfy.settings.json")

# Prefer default/workflows, fallback to user/workflows
flows_src_candidates = [
    os.path.join(local, "ComfyUI", "user", "default", "workflows"),
    os.path.join(local, "ComfyUI", "user", "workflows"),
]
flows_src = next((p for p in flows_src_candidates if os.path.isdir(p)), None)

# Prefer default/subgraphs, fallback to user/subgraphs
subgraphs_src_candidates = [
    os.path.join(local, "ComfyUI", "user", "default", "subgraphs"),
    os.path.join(local, "ComfyUI", "user", "subgraphs"),
]
subgraphs_src = next((p for p in subgraphs_src_candidates if os.path.isdir(p)), None)

userdir = os.path.join(comfy, "user", "default")
os.makedirs(userdir, exist_ok=True)

if os.path.isfile(settings_src):
    shutil.copy2(settings_src, os.path.join(userdir, "comfy.settings.json"))
    print("[restore] settings restored")

if flows_src and os.path.isdir(flows_src):
    dest = os.path.join(userdir, "workflows")
    if os.path.isdir(dest): shutil.rmtree(dest)
    shutil.copytree(flows_src, dest)
    print(f"[restore] workflows restored from {os.path.relpath(flows_src, local)}")

if subgraphs_src and os.path.isdir(subgraphs_src):
    dest = os.path.join(userdir, "subgraphs")
    for root, dirs, files in os.walk(subgraphs_src):
        rel = os.path.relpath(root, subgraphs_src)
        dstdir = os.path.join(dest, rel) if rel != "." else dest
        os.makedirs(dstdir, exist_ok=True)
        for fname in files:
            src_path = os.path.join(root, fname)
            dst_path = os.path.join(dstdir, fname)
            shutil.copy2(src_path, dst_path)
    print(f"[restore] subgraphs merged (overwrite) from {os.path.relpath(subgraphs_src, local)}")

if os.path.isfile(snap):
    import yaml, subprocess
    with open(snap, "r") as f:
        snapdata = yaml.safe_load(f) or {}

    failed = []

    # git nodes
    for repo_url, node_data in (snapdata.get("git_custom_nodes") or {}).items():
        if node_data.get("disabled"):
            continue
        name = os.path.splitext(os.path.basename(repo_url))[0]
        dest = os.path.join(comfy, "custom_nodes", name)
        if os.path.exists(dest):
            print(f"[restore] {name} already present, skipping")
            continue
        print(f"[restore] cloning {repo_url}")
        res = subprocess.run(["git", "clone", "--depth=1", repo_url, dest], text=True, capture_output=True)
        if res.returncode != 0:
            print(f"[restore][err] {repo_url}\n{res.stderr}")
            failed.append(repo_url)

    # CNR nodes
    for node_name, version in (snapdata.get("cnr_custom_nodes") or {}).items():
        print(f"[restore] cnr install {node_name} (no-deps, skip-prompt, here, cache)")
        cmd = ["comfy", "--here", "--skip-prompt", "node", "install", "--no-deps", "--mode", "cache", node_name]
        res = subprocess.run(cmd, cwd=comfy, text=True, capture_output=True)
        if res.returncode != 0:
            print(f"[restore][err] CNR {node_name}\n{res.stderr}")
            failed.append(node_name)

    if failed:
        print("[restore][warn] some nodes failed:", failed)
else:
    print("[restore] snapshot not found; nodes not changed")
PY

echo "[restore] nodes & settings done."
