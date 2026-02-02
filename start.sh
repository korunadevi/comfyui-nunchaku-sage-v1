#!/bin/bash
# Fail fast & sane IFS
set -Eeuo pipefail
IFS=$'\n\t'

# Capture all script output to a log file for the placeholder page
LOG_FILE="/server.log"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# Default venv (must be at the very top)
: "${VIRTUAL_ENV:=/workspace/ComfyUI/venv}"
export VIRTUAL_ENV

# Quiet noisy warnings and pip notices globally
export PYTHONWARNINGS="ignore"
export PIP_DISABLE_PIP_VERSION_CHECK="1"
export HF_HUB_DISABLE_TELEMETRY="1"
# Persist pip cache across runs to speed installs
export PIP_CACHE_DIR="/workspace/.cache/pip"

# --- Sanitize COMFYUI_BACKUP: must be exactly owner/repo; otherwise unset ---
if [[ -n "${COMFYUI_BACKUP-}" ]]; then
  _cb="${COMFYUI_BACKUP//[[:space:]]/}"
  if [[ "$_cb" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    COMFYUI_BACKUP="$_cb"
  else
    echo "[WARN] COMFYUI_BACKUP invalid ('${COMFYUI_BACKUP}'); unsetting."
    unset COMFYUI_BACKUP
  fi
fi

# --- CUDA preflight (bail early) ---
echo "STAGE: Checking CUDA initialization"
if ! python - <<'PY' &>/dev/null
import torch; torch.cuda.current_device()
PY
then
  cat << 'EOF'
 �������+��+  ��+��+��������+    ������+  ������+ ������+ 
 ��+----+���  ������+--��+--+    ��+--��+��+---��+��+--��+
 �������+�����������   ���       ������++���   ������   ��+
 +----�����+--������   ���       ��+---+ ���   ������  ��++
 �����������  ������   ���       ���     +������++������++
 +------++-+  +-++-+   +-+       +-+      +-----+ +-----+

       this pod has broken or outdated GPU drivers 
           deploy a new one and kill this one

EOF
  echo "CUDA initialization failed" >> ~/comfyui_error.log
  exit 1
fi

mkdir -p /workspace

# --- Temporary log page on port 8188 until ComfyUI starts ---
start_comfy_placeholder() {
  /usr/bin/env python3 /scripts/comfy_wait_page.py \
    --port 8188 --refresh 2 \
    --files /server.log \
    >> /placeholder.log 2>&1 &
  export COMFY_PLACEHOLDER_PID=$!
  echo "[placeholder] started on :8188 (pid=$COMFY_PLACEHOLDER_PID)"
}


# Start the placeholder as early as possible
start_comfy_placeholder || true

# --- AI Toolkit isolated install/update + UI (background) ---
AITK_DIR="/workspace/ai-toolkit"
AITK_REPO_DIR="$AITK_DIR/repo"
AITK_VENV="$AITK_DIR/venv"
AITK_REPO_URL="${AITK_REPO_URL:-https://github.com/ostris/ai-toolkit.git}"
AITK_UI_PORT="${AITK_UI_PORT:-8675}"

# Temporary log page on AI Toolkit port until UI starts
start_ai_toolkit_placeholder() {
  /usr/bin/env python3 /scripts/ai_toolkit_wait_page.py \
    --port "$AITK_UI_PORT" --refresh 2 \
    --files /ai_toolkit_setup.log \
    >> /aitk_placeholder.log 2>&1 &
  export AITK_PLACEHOLDER_PID=$!
  echo "[aitk placeholder] started on :$AITK_UI_PORT (pid=$AITK_PLACEHOLDER_PID)" >> /ai_toolkit_setup.log
}

start_ai_toolkit_stack() {
  exec >> /ai_toolkit_setup.log 2>&1
  set +e
  echo "[ai-toolkit] setting up in $AITK_DIR" > /ai_toolkit_setup.log
  mkdir -p "$AITK_DIR"

  if [[ ! -d "$AITK_REPO_DIR/.git" ]]; then
    echo "[ai-toolkit] cloning repo�" >> /ai_toolkit_setup.log
    git clone --depth 1 "$AITK_REPO_URL" "$AITK_REPO_DIR" >> /ai_toolkit_setup.log 2>&1 || true
  else
    echo "[ai-toolkit] updating repo�" >> /ai_toolkit_setup.log
    git -C "$AITK_REPO_DIR" pull --ff-only >> /ai_toolkit_setup.log 2>&1 || true
  fi

  if [[ ! -d "$AITK_VENV" ]]; then
    echo "[ai-toolkit] creating venv at $AITK_VENV" >> /ai_toolkit_setup.log
    python3 -m venv "$AITK_VENV" --system-site-packages >> /ai_toolkit_setup.log 2>&1 || true
  fi

  "$AITK_VENV/bin/python" -m pip install --upgrade pip wheel setuptools >> /ai_toolkit_setup.log 2>&1 || true

  if [[ -f "$AITK_REPO_DIR/requirements.txt" ]]; then
    echo "[ai-toolkit] installing requirements (excluding torch/vision/audio to keep your version)�" >> /ai_toolkit_setup.log
    tmp_req="$AITK_DIR/requirements.no-torch.txt"
    grep -Ev '^(torch|torchvision|torchaudio)($|[<>=])' "$AITK_REPO_DIR/requirements.txt" > "$tmp_req" || cp "$AITK_REPO_DIR/requirements.txt" "$tmp_req"
    "$AITK_VENV/bin/python" -m pip install -r "$tmp_req" >> /ai_toolkit_setup.log 2>&1 || true
  fi

  # Build and run UI (Node)
  if [[ -f "$AITK_REPO_DIR/ui/package.json" ]]; then
    echo "[ai-toolkit] installing UI dependencies (incl. dev) ..." >> /ai_toolkit_setup.log
    (cd "$AITK_REPO_DIR/ui" && npm install --include=dev >> /ai_toolkit_setup.log 2>&1)
    echo "[ai-toolkit] updating DB (prisma) and building UI..." >> /ai_toolkit_setup.log
    (cd "$AITK_REPO_DIR/ui" && npm run update_db >> /ai_toolkit_setup.log 2>&1)
    (cd "$AITK_REPO_DIR/ui" && npm run build >> /ai_toolkit_setup.log 2>&1)
    echo "[ai-toolkit] starting UI on :$AITK_UI_PORT (PATH prefixed with venv)" >> /ai_toolkit_setup.log
    # Stop placeholder and free the port before launching UI
    if [[ -n "${AITK_PLACEHOLDER_PID:-}" ]]; then
      kill "${AITK_PLACEHOLDER_PID}" 2>/dev/null || true
      sleep 0.5
    fi
    (cd "$AITK_REPO_DIR/ui" && env \
        PATH="$AITK_VENV/bin:$PATH" \
        VIRTUAL_ENV="$AITK_VENV" \
        PYTHON="$AITK_VENV/bin/python" \
        PORT="$AITK_UI_PORT" \
        npm run start >> /ai_toolkit_ui.log 2>&1)
  else
    echo "[ai-toolkit] ui/package.json not found; skipping UI start" >> /ai_toolkit_setup.log
  fi
  # restore -e for the rest of the script
  set -e
}

# Kick off AI Toolkit placeholder + setup/UI early (in background)
start_ai_toolkit_placeholder || true
start_ai_toolkit_stack &
service nginx start || true

# --- Helper: update repo + pip if changed ---
update_and_install_requirements() {
  cd "$1" || return
  local old="$(git rev-parse HEAD 2>/dev/null || echo)"
  git pull --ff-only || true
  local new="$(git rev-parse HEAD 2>/dev/null || echo)"
  if [[ "$old" != "$new" && -f requirements.txt ]]; then
    pip install -r requirements.txt
  fi
}

# # --- One-shot: pre_start (only if /Comfy exists) ---
# if [[ -d /Comfy ]]; then
#   if [[ -n "${COMFYUI_BACKUP-}" ]]; then
#     jq --arg v "$COMFYUI_BACKUP" \
#       '."downloaderbackup.repo_name" = $v' \
#       /Comfy/user/default/comfy.settings.json \
#       > /Comfy/user/default/tmp.settings.json
#     mv /Comfy/user/default/tmp.settings.json /Comfy/user/default/comfy.settings.json

#     rm -rf /tmp/comfy_course_tmp
#     git clone https://github.com/jnxmx/comfycourse_json.git /tmp/comfy_course_tmp
#     mkdir -p /Comfy/user/default/workflows
#     rm -rf /Comfy/user/default/workflows/comfy_course
#     mv /tmp/comfy_course_tmp /Comfy/user/default/workflows/comfy_course
#     rm -rf /Comfy/user/default/workflows/comfy_course/.git
#     echo "✅ comfy_course restored to /Comfy/user/default/workflows/comfy_course"
#   else
#     echo "COMFYUI_BACKUP not set/valid; skipping comfy_course restore."
#   fi
# else
#   echo "Second start (no /Comfy)."
# fi

## moved below backup restore to avoid being overwritten

# --- First boot: persist ComfyUI into /workspace and fetch taesd ---
if [[ ! -d /workspace/ComfyUI && -d /Comfy ]]; then
  if [[ ! -f /Comfy/models/checkpoints/taew2_1.safetensors ]]; then
    mkdir -p /Comfy/models/vae_approx
    curl -L \
      https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/taew2_1.safetensors \
      -o /Comfy/models/vae_approx/taew2_1.safetensors
  fi
  echo "Persisting ComfyUI to /workspace (first boot)…"
  mv /Comfy /workspace/ComfyUI
else
  echo "ComfyUI already present in /workspace; skipping copy."
fi

# --- Venv create/activate ---
if [[ ! -d "$VIRTUAL_ENV" ]]; then
  echo "Creating venv at $VIRTUAL_ENV…"
  python3 -m venv "$VIRTUAL_ENV" --system-site-packages
fi
if [[ -f "$VIRTUAL_ENV/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "$VIRTUAL_ENV/bin/activate"
else
  echo "Warning: $VIRTUAL_ENV/bin/activate not found; continuing without activation."
fi
echo "VIRTUAL_ENV: ${VIRTUAL_ENV:-}"
echo "PATH: $PATH"


# --- Install appropriate sageattention wheel based on GPU architecture ---
ARCH=$(python3 - <<'EOF'
import torch
if not torch.cuda.is_available():
    print("none")
    exit(0)
cap = torch.cuda.get_device_capability()[0] * 10 + torch.cuda.get_device_capability()[1]
arch_map = {120: "sm120", 86: "sm86", 89: "sm89"}
print(arch_map.get(cap, "none"))
EOF
)

if [ "$ARCH" != "none" ]; then
    echo "STAGE: Installing sageattention"
    WHEEL_FILE=$(find /wheels -type f -name "sageattention-*+${ARCH}-*.whl" | head -n 1)
    if [ -n "$WHEEL_FILE" ]; then
        echo "Installing sageattention wheel for architecture $ARCH"
        pip install --no-deps "$WHEEL_FILE"
    else
        echo "No matching wheel found for architecture $ARCH, falling back to pip"
        pip install sageattention==1.0.6
    fi
else
    echo "STAGE: Installing sageattention"
    echo "Installing sageattention from pip"
    pip install sageattention==1.0.6
fi

    echo "Installing sageattention from pip"
    pip install sageattention==1.0.6
fi

# --- [PREMIUM] Install Nunchaku ---
if [[ -x "/scripts/install_nunchaku.sh" ]]; then
    /scripts/install_nunchaku.sh
fi

# --- Optional first-boot restore (external scripts) ---
echo "RESTORE_BACKUP: ${RESTORE_BACKUP:-}"
echo "COMFYUI_BACKUP: ${COMFYUI_BACKUP:-}"
if [[ "${RESTORE_BACKUP:-0}" == "1" && -n "${COMFYUI_BACKUP:-}" && -d "/workspace/ComfyUI" && ! -f "/workspace/.restore_done" ]]; then
  echo "STAGE: Restoring backup"
  echo "[INFO] First-boot restore from ${COMFYUI_BACKUP}…"
  pip install -q huggingface_hub PyYAML hf_transfer || true
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  [[ -x "${script_dir}/scripts/restore_models.sh" ]] && (cd /workspace/ComfyUI && "${script_dir}/scripts/restore_models.sh") &> /restore.log &
  [[ -x "${script_dir}/scripts/restore_nodes_and_settings.sh" ]] && (cd /workspace/ComfyUI && "${script_dir}/scripts/restore_nodes_and_settings.sh")
  touch /workspace/.restore_done
else
  echo "Backup restore skipped."
fi



# --- Restore comfy_course workflows when NOT in student mode ---
# Supports both pre-persist (/Comfy) and post-persist (/workspace/ComfyUI) layouts.
if [[ "${STUDENT_MODE:-0}" != "1" ]]; then
  target_user_dir=""
  if [[ -d "/workspace/ComfyUI/user/default" ]]; then
    target_user_dir="/workspace/ComfyUI/user/default"
  elif [[ -d "/Comfy/user/default" ]]; then
    target_user_dir="/Comfy/user/default"
  fi

  if [[ -n "$target_user_dir" ]]; then
    rm -rf /tmp/comfy_course_tmp
    # Avoid exiting the whole script if network is flaky; check directory before moving
    if git clone --depth=1 https://github.com/jnxmx/comfycourse_json.git /tmp/comfy_course_tmp 2>/dev/null; then
      mkdir -p "$target_user_dir/workflows"
      if [[ -d "$target_user_dir/workflows/comfy_course" ]]; then
        echo "[course] comfy_course present; replacing with latest"
        rm -rf "$target_user_dir/workflows/comfy_course"
      fi
      mv /tmp/comfy_course_tmp "$target_user_dir/workflows/comfy_course"
      rm -rf "$target_user_dir/workflows/comfy_course/.git"
      echo "[course] comfy_course restored to $target_user_dir/workflows/comfy_course"
    else
      echo "[course][warn] failed to clone comfycourse_json; skipping restore"
    fi
  else
    echo "[course] no Comfy user dir found; skipping comfy_course restore"
  fi
fi

# --- Always set downloaderbackup repo in comfy.settings.json when COMFYUI_BACKUP is provided ---
if [[ -n "${COMFYUI_BACKUP-}" ]]; then
  for settings in \
      /workspace/ComfyUI/user/default/comfy.settings.json \
      /Comfy/user/default/comfy.settings.json; do
    if [[ -f "$settings" ]]; then
      tmp="${settings}.tmp"
      jq --arg v "$COMFYUI_BACKUP" '."downloaderbackup.repo_name" = $v' "$settings" > "$tmp" && mv "$tmp" "$settings"
      echo "[settings] downloaderbackup.repo_name set in $settings"
    fi
  done
fi

# --- Update core + custom nodes when repos change (idempotent) ---
if [[ -d /workspace/ComfyUI ]]; then
  echo "STAGE: Updating ComfyUI core"
  update_and_install_requirements /workspace/ComfyUI || true

  echo "STAGE: Updating custom nodes"
  if command -v comfy >/dev/null 2>&1; then
    # Use cache mode to reduce remote registry fetches; hide noisy cm-cli banners
    (
      cd /workspace/ComfyUI && \
      comfy --here --skip-prompt node update all --mode cache
    ) 2>&1 | grep -vE '^(Command: \[|Execute from: )' || true
  else
    for d in /workspace/ComfyUI/custom_nodes/*/; do
      if [[ -d "$d/.git" ]]; then
        node_name="$(basename "$d")"
        echo "[nodes] refreshing ${node_name}"
        update_and_install_requirements "$d" || true
      fi
    done
  fi
fi


echo "pod started"

# --- SSH key (optional) ---
if [[ -n "${PUBLIC_KEY:-}" ]]; then
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  service ssh start
fi

# --- AI Toolkit isolated install/update + UI (background) ---
AITK_DIR="/workspace/ai-toolkit"
AITK_REPO_DIR="$AITK_DIR/repo"
AITK_VENV="$AITK_DIR/venv"
AITK_REPO_URL="${AITK_REPO_URL:-https://github.com/ostris/ai-toolkit.git}"
AITK_UI_PORT="${AITK_UI_PORT:-8675}"

start_ai_toolkit_stack() {
  set +e
  echo "[ai-toolkit] setting up in $AITK_DIR" > /ai_toolkit_setup.log
  mkdir -p "$AITK_DIR"

  if [[ ! -d "$AITK_REPO_DIR/.git" ]]; then
    echo "[ai-toolkit] cloning repo…" >> /ai_toolkit_setup.log
    git clone --depth 1 "$AITK_REPO_URL" "$AITK_REPO_DIR" >> /ai_toolkit_setup.log 2>&1 || true
  else
    echo "[ai-toolkit] updating repo…" >> /ai_toolkit_setup.log
    git -C "$AITK_REPO_DIR" pull --ff-only >> /ai_toolkit_setup.log 2>&1 || true
  fi

  if [[ ! -d "$AITK_VENV" ]]; then
    echo "[ai-toolkit] creating venv at $AITK_VENV" >> /ai_toolkit_setup.log
    python3 -m venv "$AITK_VENV" --system-site-packages >> /ai_toolkit_setup.log 2>&1 || true
  fi

  # Pip/bootstrap inside isolated venv (reusing system PyTorch via --system-site-packages)
  "$AITK_VENV/bin/python" -m pip install --upgrade pip wheel setuptools >> /ai_toolkit_setup.log 2>&1 || true

  if [[ -f "$AITK_REPO_DIR/requirements.txt" ]]; then
    echo "[ai-toolkit] installing requirements (excluding torch/vision/audio to keep your version)…" >> /ai_toolkit_setup.log
    tmp_req="$AITK_DIR/requirements.no-torch.txt"
    grep -Ev '^(torch|torchvision|torchaudio)($|[<>=])' "$AITK_REPO_DIR/requirements.txt" > "$tmp_req" || cp "$AITK_REPO_DIR/requirements.txt" "$tmp_req"
    "$AITK_VENV/bin/python" -m pip install -r "$tmp_req" >> /ai_toolkit_setup.log 2>&1 || true
  fi

  # Skip editable install to avoid pulling conflicting torch deps; UI runs via Node

  # Build and run UI (Node)
  if [[ -f "$AITK_REPO_DIR/ui/package.json" ]]; then
    echo "[ai-toolkit] installing UI dependencies (incl. dev) ..." >> /ai_toolkit_setup.log
    (cd "$AITK_REPO_DIR/ui" && npm install --include=dev >> /ai_toolkit_setup.log 2>&1)
    echo "[ai-toolkit] updating DB (prisma) and building UI..." >> /ai_toolkit_setup.log
    (cd "$AITK_REPO_DIR/ui" && npm run update_db >> /ai_toolkit_setup.log 2>&1)
    (cd "$AITK_REPO_DIR/ui" && npm run build >> /ai_toolkit_setup.log 2>&1)
    echo "[ai-toolkit] starting UI on :$AITK_UI_PORT (PATH prefixed with venv)" >> /ai_toolkit_setup.log
    (cd "$AITK_REPO_DIR/ui" && env \
        PATH="$AITK_VENV/bin:$PATH" \
        VIRTUAL_ENV="$AITK_VENV" \
        PYTHON="$AITK_VENV/bin/python" \
        PORT="$AITK_UI_PORT" \
        npm run start >> /ai_toolkit_ui.log 2>&1)
  else
    echo "[ai-toolkit] ui/package.json not found; skipping UI start" >> /ai_toolkit_setup.log
  fi
  # restore -e for the rest of the script
  set -e
}

# --- Start jupyterr ---
cd /
jupyter lab \
  --ip=0.0.0.0 \
  --port=8888 \
  --no-browser \
  --allow-root \
  --NotebookApp.allow_origin='*' \
  --ServerApp.token='' \
  --ServerApp.password='' \
  --FileContentsManager.preferred_dir=/workspace \
  --FileContentsManager.delete_to_trash=False \
  --ServerApp.terminado_settings='{"shell_command":["/bin/bash","-l"]}' \
  &> /jupyter.log &

# Start filebrowser
filebrowser --address=0.0.0.0 --port=8080 --root=/workspace/ --noauth &

service nginx start

echo "JupyterLab and Filebrowser started; nginx up."

# --- Launch ComfyUI ---
cd /workspace/ComfyUI
# Stop placeholder and free :8188 before launching ComfyUI
if [[ -n "${COMFY_PLACEHOLDER_PID:-}" ]]; then
  kill "${COMFY_PLACEHOLDER_PID}" 2>/dev/null || true
  # wait briefly for port to release
  sleep 0.5
fi
echo "STAGE: Starting ComfyUI"
"$VIRTUAL_ENV/bin/python" main.py \
  --listen 0.0.0.0 --port 8188 # \
#  --preview-method taesd # \
#  --front-end-version Comfy-Org/ComfyUI_frontend@latest &

sleep infinity
