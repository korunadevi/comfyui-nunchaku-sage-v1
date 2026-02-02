#!/usr/bin/env python3
import argparse
import http.server
import importlib
import json
import os
import re
import socketserver
import time
from pathlib import Path

LOG_TAIL_BYTES = 200_000
SNAPSHOT_PATH = Path("/workspace/.backup_tmp/hf_pull/ComfyUI/custom_nodes_snapshot.yaml")

RESTORE_CLONE_RE = re.compile(r"\[restore\]\s+cloning\s+(.+)", re.I)
RESTORE_CNR_RE = re.compile(r"\[restore\]\s+cnr install\s+([A-Za-z0-9._-]+)", re.I)
RESTORE_SKIP_RE = re.compile(r"\[restore\]\s+([A-Za-z0-9._-]+)\s+already present", re.I)
RESTORE_ERR_RE = re.compile(r"\[restore]\[err[^\]]*\]\s*([^\s]+)", re.I)
RESTORE_DONE_RE = re.compile(r"\[restore\]\s+nodes\s+&\s+settings\s+done", re.I)
RESTORE_FAIL_LIST_RE = re.compile(r"\[restore]\[warn].*failed:\s*\[(.+)\]", re.I)

NODE_PROGRESS_RE = [
    re.compile(r"\[nodes\]\s+refreshing\s+([A-Za-z0-9._-]+)", re.I),
    re.compile(r"(?:Updating|Installing)\s+([A-Za-z0-9._-]+)", re.I),
    re.compile(r"\[manager][^\]]*\]\s*([A-Za-z0-9._-]+)", re.I),
]


def _bool_env(value: str, default: str = "0") -> bool:
    raw = str(value if value is not None else default).strip().lower()
    return raw in {"1", "true", "yes", "on"}


ENV_INFO = {
    "backup_repo": (os.environ.get("COMFYUI_BACKUP") or "").strip() or None,
    "restore_enabled": _bool_env(os.environ.get("RESTORE_BACKUP", "0")),
    "hf_token": bool((os.environ.get("HF_TOKEN") or "").strip()),
    "civitai_token": bool((os.environ.get("CIVITAI_TOKEN") or "").strip()),
}


def _regex(pattern: str) -> re.Pattern:
    return re.compile(pattern, re.I)


def _backup_detail(_: dict, backup_state: dict) -> str:
    repo = ENV_INFO["backup_repo"]
    if not repo:
        return "Backup is not set"
    if not ENV_INFO["restore_enabled"]:
        return f"Backup {repo} configured but RESTORE_BACKUP=0"
    total = len(backup_state.get("nodes") or [])
    if total:
        return f"Restoring {total} custom nodes from {repo}"
    return f"Restoring backup from {repo}"


def _update_backup_detail(line: str, current: str) -> str:
    clone = RESTORE_CLONE_RE.search(line)
    if clone:
        return f"Cloning {_repo_label(clone.group(1))}"
    cnr = RESTORE_CNR_RE.search(line)
    if cnr:
        return f"Installing {cnr.group(1)} from snapshot"
    return current


def _update_custom_detail(line: str, current: str) -> str:
    for pattern in NODE_PROGRESS_RE:
        match = pattern.search(line)
        if match:
            name = match.group(1)
            if name.lower().startswith("http"):
                name = _repo_label(name)
            return f"Updating {name}"
    return current


STAGE_DEFS = [
    {
        "id": "bootstrap",
        "label": "GPU & workspace",
        "detail": "Checking CUDA drivers and preparing /workspace",
        "patterns": [
            _regex(r"STAGE:\s*Checking CUDA"),
            _regex(r"Persisting ComfyUI"),
            _regex(r"ComfyUI already present"),
        ],
    },
    {
        "id": "venv",
        "label": "Python environment",
        "detail": "Creating venv and upgrading pip",
        "patterns": [
            _regex(r"Creating venv"),
            _regex(r"VIRTUAL_ENV:"),
        ],
    },
    {
        "id": "wheels",
        "label": "Extra wheels",
        "detail": "Installing sageattention",
        "patterns": [
            _regex(r"STAGE:\s*Installing sageattention"),
        ],
    },
    {
        "id": "backup-manager",
        "label": "ComfyUI manager",
        "detail": "Fetching ComfyUI manager metadata (first boot can take up to 2 minutes while registry downloads)",
        "patterns": [
            _regex(r"STAGE:\s*Preparing ComfyUI Manager"),
        ],
    },
    {
        "id": "backup-nodes",
        "label": "Backup restore",
        "detail_factory": _backup_detail,
        "patterns": [
            _regex(r"STAGE:\s*Installing nodes from backup"),
            _regex(r"STAGE:\s*Restoring backup"),
        ],
        "detail_from_line": _update_backup_detail,
    },
    {
        "id": "core",
        "label": "ComfyUI core",
        "detail": "Updating base repo and Python dependencies",
        "patterns": [
            _regex(r"STAGE:\s*Updating ComfyUI core"),
        ],
    },
    {
        "id": "custom",
        "label": "Custom nodes",
        "detail": "Updating registered nodes",
        "patterns": [
            _regex(r"STAGE:\s*Updating custom nodes"),
        ],
        "detail_from_line": _update_custom_detail,
    },
    {
        "id": "launch",
        "label": "Launch",
        "detail": "Starting ComfyUI on :8188",
        "patterns": [
            _regex(r"STAGE:\s*Starting ComfyUI"),
        ],
    },
]


def tail_lines(path: str, max_bytes: int = LOG_TAIL_BYTES):
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(size - max_bytes, 0))
            data = handle.read().decode("utf-8", errors="ignore")
            return data.splitlines()
    except OSError:
        return []


_SNAPSHOT_CACHE = {"mtime": None, "nodes": []}


def _repo_label(repo_url: str) -> str:
    cleaned = repo_url.strip().rstrip("/")
    if cleaned.endswith(".git"):
        cleaned = cleaned[:-4]
    return cleaned.split("/")[-1] if "/" in cleaned else cleaned


def _normalize_repo(repo_url: str) -> str:
    cleaned = repo_url.strip()
    if cleaned.endswith(".git"):
        cleaned = cleaned[:-4]
    return cleaned.rstrip("/")


def _load_backup_nodes():
    if not SNAPSHOT_PATH.exists():
        _SNAPSHOT_CACHE["mtime"] = None
        _SNAPSHOT_CACHE["nodes"] = []
        return []
    current_mtime = SNAPSHOT_PATH.stat().st_mtime
    if _SNAPSHOT_CACHE["mtime"] == current_mtime:
        return _SNAPSHOT_CACHE["nodes"]
    try:
        yaml = importlib.import_module("yaml")
    except Exception:
        return []
    try:
        data = yaml.safe_load(SNAPSHOT_PATH.read_text(encoding="utf-8")) or {}
    except Exception:
        return []
    nodes = []
    for repo_url, node_data in (data.get("git_custom_nodes") or {}).items():
        if isinstance(node_data, dict) and node_data.get("disabled"):
            continue
        label = None
        if isinstance(node_data, dict):
            label = node_data.get("name")
        nodes.append(
            {
                "key": _repo_label(repo_url),
                "name": label or _repo_label(repo_url),
                "source": "git",
                "repo": _normalize_repo(repo_url),
            }
        )
    for node_name, version in (data.get("cnr_custom_nodes") or {}).items():
        nodes.append(
            {
                "key": str(node_name),
                "name": str(node_name),
                "source": "cnr",
                "version": "" if version is None else str(version),
            }
        )
    _SNAPSHOT_CACHE["nodes"] = nodes
    _SNAPSHOT_CACHE["mtime"] = current_mtime
    return nodes


def _apply_backup_progress(nodes, lines):
    if not nodes:
        return nodes
    index_by_key = {node["key"]: i for i, node in enumerate(nodes)}
    index_by_repo = {
        node["repo"]: i for i, node in enumerate(nodes) if node.get("repo")
    }
    for node in nodes:
        node["status"] = node.get("status") or "pending"
    active_idx = None
    for line in lines:
        clone = RESTORE_CLONE_RE.search(line)
        if clone:
            key = index_by_repo.get(_normalize_repo(clone.group(1)))
            if key is not None:
                if (
                    active_idx is not None
                    and nodes[active_idx]["status"] == "installing"
                    and active_idx != key
                ):
                    nodes[active_idx]["status"] = "done"
                active_idx = key
                nodes[key]["status"] = "installing"
            continue
        cnr = RESTORE_CNR_RE.search(line)
        if cnr:
            key = index_by_key.get(cnr.group(1).strip())
            if key is not None:
                if (
                    active_idx is not None
                    and nodes[active_idx]["status"] == "installing"
                    and active_idx != key
                ):
                    nodes[active_idx]["status"] = "done"
                active_idx = key
                nodes[key]["status"] = "installing"
            continue
        skip = RESTORE_SKIP_RE.search(line)
        if skip:
            node_key = skip.group(1).strip()
            idx = index_by_key.get(node_key) or index_by_repo.get(
                _normalize_repo(node_key)
            )
            if idx is not None:
                nodes[idx]["status"] = "done"
            continue
        err_match = RESTORE_ERR_RE.search(line)
        if err_match:
            node_key = err_match.group(1).strip()
            idx = index_by_key.get(node_key) or index_by_repo.get(
                _normalize_repo(node_key)
            )
            if idx is not None:
                nodes[idx]["status"] = "failed"
            continue
        fail_list = RESTORE_FAIL_LIST_RE.search(line)
        if fail_list:
            failed_nodes = fail_list.group(1).split(",")
            for key in failed_nodes:
                idx = index_by_key.get(key.strip()) or index_by_repo.get(
                    _normalize_repo(key.strip())
                )
                if idx is not None:
                    nodes[idx]["status"] = "failed"
            continue
        if RESTORE_DONE_RE.search(line):
            for node in nodes:
                if node["status"] in {"pending", "installing"}:
                    node["status"] = "done"
            active_idx = None
    if active_idx is not None and nodes[active_idx]["status"] == "installing":
        for idx in range(active_idx):
            if nodes[idx]["status"] == "pending":
                nodes[idx]["status"] = "done"
    return nodes


def build_backup_state(lines):
    enabled = ENV_INFO["restore_enabled"] and ENV_INFO["backup_repo"]
    nodes = []
    has_manifest = False
    if enabled:
        nodes = [dict(node) for node in _load_backup_nodes()]
        has_manifest = bool(nodes)
        nodes = _apply_backup_progress(nodes, lines)
    if not ENV_INFO["backup_repo"]:
        message = "Backup is not set."
    elif not ENV_INFO["restore_enabled"]:
        message = "Backup is configured but RESTORE_BACKUP=0."
    elif not nodes:
        message = "Waiting for backup snapshot manifest..."
    else:
        completed = sum(1 for node in nodes if node["status"] == "done")
        message = f"{completed}/{len(nodes)} nodes processed from {ENV_INFO['backup_repo']}."
    return {
        "enabled": bool(enabled),
        "repo": ENV_INFO["backup_repo"],
        "nodes": nodes,
        "has_manifest": has_manifest,
        "message": message,
    }


def compute_stage_states(lines, backup_state):
    stages = []
    skip_ids = set()
    if not backup_state["enabled"]:
        skip_ids.update({"backup-manager", "backup-nodes"})
    for definition in STAGE_DEFS:
        base_detail = definition.get("detail")
        if callable(definition.get("detail_factory")):
            base_detail = definition["detail_factory"](ENV_INFO, backup_state)
        stages.append(
            {
                "id": definition["id"],
                "label": definition["label"],
                "detail": base_detail or "",
                "status": "pending",
                "skipped": definition["id"] in skip_ids,
            }
        )
        if definition["id"] in skip_ids:
            stages[-1]["status"] = "done"
    current_idx = None
    for line in lines:
        for idx, definition in enumerate(STAGE_DEFS):
            if stages[idx]["skipped"]:
                continue
            if any(pattern.search(line) for pattern in definition["patterns"]):
                current_idx = idx
                detail_fn = definition.get("detail_from_line")
                if detail_fn:
                    new_detail = detail_fn(line, stages[idx]["detail"])
                    if new_detail:
                        stages[idx]["detail"] = new_detail
                break
    if current_idx is None:
        for idx, stage in enumerate(stages):
            if stage["skipped"]:
                continue
            stage["status"] = "active"
            break
        return stages
    for idx, stage in enumerate(stages):
        if stage["skipped"]:
            continue
        if idx < current_idx:
            stage["status"] = "done"
        elif idx == current_idx:
            stage["status"] = "active"
        else:
            stage["status"] = "pending"
    return stages


def build_state_payload(log_path):
    lines = tail_lines(log_path)
    backup_state = build_backup_state(lines)
    return {
        "timestamp": time.time(),
        "stages": compute_stage_states(lines, backup_state),
        "backup": backup_state,
        "env": {
            "backup_repo": ENV_INFO["backup_repo"],
            "restore_enabled": ENV_INFO["restore_enabled"],
            "hf_token": ENV_INFO["hf_token"],
            "civitai_token": ENV_INFO["civitai_token"],
        },
    }


HTML_PAGE = """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ComfyUI is starting…</title>
  <style>
    @font-face { font-family: 'Inter'; font-style: normal; font-weight: 400; font-display: swap; src: url('/assets/fonts/Inter-latin.woff2') format('woff2'); }
    @font-face { font-family: 'Inter'; font-style: normal; font-weight: 600; font-display: swap; src: url('/assets/fonts/Inter-latin.woff2') format('woff2'); }
    html, body { margin: 0; padding: 0; min-height: 100%; background: #d8cec9; color: #0c4eb9; font-family: 'Inter', sans-serif; }
    body { display: flex; align-items: stretch; }
    .wrapper { max-width: 900px; margin: 0 auto; padding: 2rem 1.5rem 2.5rem; display: flex; flex-direction: column; gap: 1.5rem; width: 100%; }
    h1 { margin: 0; font-size: 2rem; font-weight: 600; }
    .linkline { font-size: 0.95rem; letter-spacing: 0.08em; text-transform: uppercase; margin-top: 0.15rem; }
    a { color: #d97725; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .note { font-size: 1rem; line-height: 1.55; }
    .stage-list { list-style: none; padding: 0; margin: 0; border-top: 1px solid rgba(12,78,185,0.3); }
    .stage { display: flex; justify-content: space-between; align-items: baseline; gap: 1rem; padding: 0.65rem 0; border-bottom: 1px solid rgba(12,78,185,0.15); }
    .stage-label { font-weight: 600; font-size: 1rem; }
    .stage-detail { font-size: 0.95rem; opacity: 0.9; text-align: right; flex: 1; }
    .stage.stage-active .stage-label { color: #0c4eb9; }
    .stage.stage-done .stage-label { color: rgba(12,78,185,0.7); }
    .stage.stage-pending .stage-label { color: rgba(12,78,185,0.4); }
    .stage.stage-skipped .stage-label { color: rgba(12,78,185,0.4); text-decoration: line-through; }
    .backup-panel { border: 1px solid rgba(12,78,185,0.35); border-radius: 10px; padding: 1rem; background: rgba(255,255,255,0.35); }
    .backup-header { font-weight: 600; margin-bottom: 0.35rem; }
    .backup-message { font-size: 0.95rem; margin-bottom: 0.5rem; }
    .backup-list { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 0.35rem; max-height: 220px; overflow-y: auto; }
    .backup-item { display: flex; justify-content: space-between; align-items: baseline; font-size: 0.93rem; }
    .backup-name { font-weight: 600; }
    .badge { font-size: 0.8rem; padding: 0.1rem 0.4rem; border-radius: 999px; border: 1px solid rgba(12,78,185,0.3); text-transform: uppercase; letter-spacing: 0.04em; }
    .badge.status-installing { border-color: #0c4eb9; color: #0c4eb9; }
    .badge.status-done { border-color: #357a38; color: #357a38; }
    .badge.status-failed { border-color: #b81b1b; color: #b81b1b; }
    .badge.status-pending { border-color: rgba(12,78,185,0.4); color: rgba(12,78,185,0.6); }
    .env-line { font-size: 0.9rem; }
    .manager-note { font-size: 0.9rem; color: rgba(12,78,185,0.85); display: none; }
    .manager-note.active { display: block; }
    @media (max-width: 640px) {
      .stage { flex-direction: column; align-items: flex-start; }
      .stage-detail { text-align: left; }
      .backup-item { flex-direction: column; align-items: flex-start; }
    }
  </style>
</head>
<body>
  <div class="wrapper">
    <header>
      <h1>comfy.course template</h1>
      <div class="linkline"><a href="https://course.yakushev.fr/" target="_blank" rel="noopener">course,yakushev.fr</a></div>
    </header>
    <section class="note">
      Monitoring the ComfyUI startup sequence. This page stays put and redirects automatically once the UI responds.
    </section>
    <div class="manager-note" data-manager-note>
      Fetching ComfyUI manager metadata. First boot can take up to 2 minutes while the registry downloads.
    </div>
    <ul class="stage-list" data-stage-list></ul>
    <div class="backup-panel" data-backup-panel>
      <div class="backup-header">Backup progress</div>
      <div class="backup-message" data-backup-message></div>
      <ul class="backup-list" data-backup-list></ul>
    </div>
    <section class="note">
      ComfyUI will start soon. If it takes more than 5 minutes, redeploy the pod to restart the process.
    </section>
    <div class="env-line" data-env-line></div>
  </div>
  <script>
    const stageList = document.querySelector('[data-stage-list]');
    const backupPanel = document.querySelector('[data-backup-panel]');
    const backupList = document.querySelector('[data-backup-list]');
    const backupMessage = document.querySelector('[data-backup-message]');
    const envLine = document.querySelector('[data-env-line]');
    const managerNote = document.querySelector('[data-manager-note]');

    function asBadge(status) {
      const span = document.createElement('span');
      span.className = `badge status-${status}`;
      const label = status.charAt(0).toUpperCase() + status.slice(1);
      span.textContent = label;
      return span;
    }

    function renderStages(stages) {
      if (!Array.isArray(stages)) return;
      stageList.innerHTML = '';
      stages.forEach((stage) => {
        const li = document.createElement('li');
        li.className = `stage stage-${stage.status}${stage.skipped ? ' stage-skipped' : ''}`;
        const label = document.createElement('span');
        label.className = 'stage-label';
        label.textContent = stage.label;
        const detail = document.createElement('span');
        detail.className = 'stage-detail';
        detail.textContent = stage.detail || '';
        li.appendChild(label);
        li.appendChild(detail);
        stageList.appendChild(li);
      });
      const managerStage = stages.find((s) => s.id === 'backup-manager');
      if (managerStage && managerStage.status === 'active') {
        managerNote.classList.add('active');
      } else {
        managerNote.classList.remove('active');
      }
    }

    function renderBackup(backup) {
      if (!backup) {
        backupPanel.style.display = 'none';
        return;
      }
      backupPanel.style.display = 'block';
      backupMessage.textContent = backup.message || '';
      backupList.innerHTML = '';
      if (Array.isArray(backup.nodes) && backup.nodes.length) {
        backup.nodes.forEach((node) => {
          const row = document.createElement('li');
          row.className = 'backup-item';
          const name = document.createElement('span');
          name.className = 'backup-name';
          name.textContent = node.name;
          const status = asBadge(node.status || 'pending');
          row.appendChild(name);
          row.appendChild(status);
          backupList.appendChild(row);
        });
      }
    }

    function renderEnv(env) {
      if (!env) return;
      const parts = [];
      if (env.backup_repo) {
        parts.push(`Backup: ${env.backup_repo}`);
      } else {
        parts.push('Backup: not configured');
      }
      parts.push(`HF_TOKEN: ${env.hf_token ? 'set' : 'not set'}`);
      parts.push(`CIVITAI_TOKEN: ${env.civitai_token ? 'set' : 'not set'}`);
      envLine.textContent = parts.join(' • ');
    }

    async function fetchState() {
      try {
        const res = await fetch('/state?ts=' + Date.now(), { cache: 'no-store' });
        if (res.ok) {
          const data = await res.json();
          renderStages(data.stages);
          renderBackup(data.backup);
          renderEnv(data.env);
        }
      } catch (err) {
        // swallow while backend warms up
      } finally {
        window.setTimeout(fetchState, 2000);
      }
    }

    async function probeReady() {
      try {
        const res = await fetch('/ready?ts=' + Date.now(), { cache: 'no-store' });
        if (res.status === 200) {
          const text = (await res.text()).trim();
          if (text !== 'placeholder') {
            window.location.replace('/');
            return;
          }
        } else if (res.status === 404) {
          window.location.replace('/');
          return;
        } else if (res.status === 502) {
          window.location.replace('/502.html');
          return;
        }
      } catch (err) {
        // ignore network hiccups
      }
      window.setTimeout(probeReady, 2000);
    }

    fetchState();
    probeReady();
  </script>
</body>
</html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    log_path: str = "/server.log"

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/healthz"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        if self.path.startswith("/status"):
            data = b"placeholder"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path.startswith("/state"):
            payload = build_state_payload(self.log_path)
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(200)
        encoded = HTML_PAGE.encode("utf-8")
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


class ReuseTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8188)
    parser.add_argument("--refresh", type=int, default=2)  # kept for compatibility
    parser.add_argument("--files", nargs="*", default=["/server.log"])
    args = parser.parse_args()
    Handler.log_path = args.files[0]
    with ReuseTCPServer(("", args.port), Handler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
