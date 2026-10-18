"""Small, private activity ledger for the local desktop application."""

from __future__ import annotations

from contextvars import ContextVar
import json
import os
from pathlib import Path
import re
import threading
import uuid

from .instrument import ToolEvent

desktop_probe: ContextVar[bool] = ContextVar("desktop_probe", default=False)
EVENT_LIMIT = 100
TASK_LIMIT = 50
TASK_ID = re.compile(r"[a-f0-9]{12}\Z")


def redact(value: object, token: str = "") -> str:
    text = str(value or "")
    if token:
        text = text.replace(token, "[REDACTED]")
    return re.sub(r"(?i)Bearer\s+[^\s\"']+", "Bearer [REDACTED]", text)


def _is_probe() -> bool:
    # Streamable HTTP forwards each request to an existing session task.
    from fastmcp.server.dependencies import get_http_headers

    headers = get_http_headers()
    if headers:
        return headers.get("x-local-ops-desktop") == "1"
    return desktop_probe.get()


class DesktopMonitor:
    def __init__(self, state_dir: Path) -> None:
        self.path = state_dir / "desktop-events.json"
        self.active_path = state_dir / "desktop-active.json"
        self.active: dict[str, str] = {}
        self._lock = threading.Lock()

    def on_tool_started(self, call_id: str, tool: str, started_at: str) -> None:
        if not _is_probe():
            with self._lock:
                self.active[call_id] = tool
                self._write(self.active_path, {"pid": os.getpid(), "calls": self.active})

    def _write(self, path: Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.parent.chmod(0o700)
        temporary = path.with_name(f".desktop-{uuid.uuid4().hex}.tmp")
        try:
            with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as handle:
                json.dump(value, handle, ensure_ascii=False)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)

    def on_tool_event(self, event: ToolEvent) -> None:
        if _is_probe():
            return
        summary = event.result_summary or {}
        ok = event.ok and summary.get("success") is not False
        # Titles and exceptions can contain shell commands, file bodies or secrets.
        item = {
            "id": uuid.uuid4().hex,
            "tool": event.tool,
            "title": event.tool,
            "started_at": event.started_at,
            "duration_ms": event.duration_ms,
            "ok": ok,
        }
        if not ok:
            code = summary.get("error_code")
            item["error"] = code if isinstance(code, str) and re.fullmatch(r"[a-z_]{1,80}", code) else "工具调用失败"
        with self._lock:
            self.active.pop(str(event.extra.get("desktop_call_id", "")), None)
            self._write(self.active_path, {"pid": os.getpid(), "calls": self.active})
            items = _read_json(self.path, [], 256_000)
            items = items if isinstance(items, list) else []
            items = (items + [item])[-EVENT_LIMIT:]
            self._write(self.path, items)


def _read_json(path: Path, default: object, limit: int) -> object:
    try:
        if path.is_symlink() or path.stat().st_size > limit:
            return default
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _tail(path: Path, token: str) -> str:
    try:
        if path.is_symlink():
            return ""
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            handle.seek(max(0, handle.tell() - 6000))
            return redact(handle.read(6000).decode("utf-8", errors="replace"), token)[-4000:]
    except OSError:
        return ""


def snapshot(state_dir: Path, token: str = "") -> dict[str, object]:
    """Read TaskStore's on-disk format without initializing or changing the store."""
    raw = _read_json(state_dir / "desktop-events.json", [], 256_000)
    events = [item for item in raw if isinstance(item, dict)][-EVENT_LIMIT:] if isinstance(raw, list) else []
    tasks = []
    active_count = 0
    tasks_dir = state_dir / "tasks"
    if tasks_dir.is_dir() and not tasks_dir.is_symlink():
        for path in tasks_dir.iterdir():
            if not TASK_ID.fullmatch(path.name) or path.is_symlink():
                continue
            meta = _read_json(path / "meta.json", {}, 256_000)
            if not isinstance(meta, dict) or meta.get("task_id") != path.name:
                continue
            active_count += meta.get("status") in {"queued", "running"}
            tasks.append(meta)
    tasks.sort(key=lambda item: str(item.get("updated_at", "")), reverse=True)
    visible = []
    for meta in tasks[:TASK_LIMIT]:
        item = {key: redact(meta.get(key), token)[:2000] for key in (
            "task_id", "task", "executor", "cwd", "status", "created_at", "updated_at"
        )}
        directory = tasks_dir / item["task_id"]
        item["stdout_tail"] = _tail(directory / "stdout.log", token)
        item["stderr_tail"] = _tail(directory / "stderr.log", token)
        visible.append(item)
    active = _read_json(state_dir / "desktop-active.json", {}, 256_000)
    active_calls = 0
    if isinstance(active, dict) and isinstance(active.get("pid"), int) and isinstance(active.get("calls"), dict):
        try:
            if active["pid"] > 0:
                os.kill(active["pid"], 0)
                active_calls = len(active["calls"])
        except OSError:
            pass
    return {
        "success": True,
        "events": events,
        "tasks": visible,
        "last_activity_at": events[-1].get("started_at") if events else None,
        "active_task_count": active_count,
        "active_call_count": active_calls,
    }
