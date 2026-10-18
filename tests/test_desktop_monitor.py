from __future__ import annotations

import json
from pathlib import Path
import shlex
import sys
import time

from notion_local_ops_mcp.desktop_monitor import DesktopMonitor, desktop_probe, snapshot
from notion_local_ops_mcp.executors import ExecutorRegistry
from notion_local_ops_mcp.instrument import ToolEvent, clear_sinks, register_sink, traced
from notion_local_ops_mcp.tasks import TaskStore


def test_monitor_bounds_events_and_omits_tool_payloads(tmp_path: Path) -> None:
    monitor = DesktopMonitor(tmp_path)
    event = ToolEvent("run_command", "run_command → private-token", {"command": "private-token"}, {"success": False, "error_code": "failed"}, "2026-01-01T00:00:00Z", 3, True, "private-token")
    for _ in range(110):
        monitor.on_tool_event(event)
    result = snapshot(tmp_path)
    assert len(result["events"]) == 100
    assert result["events"][-1]["ok"] is False
    assert result["events"][-1]["error"] == "failed"
    assert "private-token" not in (tmp_path / "desktop-events.json").read_text()
    assert (tmp_path / "desktop-events.json").stat().st_mode & 0o777 == 0o600
    assert tmp_path.stat().st_mode & 0o777 == 0o700


def test_monitor_excludes_desktop_probes_and_tracks_inflight(tmp_path: Path) -> None:
    clear_sinks()
    register_sink(DesktopMonitor(tmp_path))

    @traced("read_text")
    def tool():
        return snapshot(tmp_path)["active_call_count"]

    try:
        marker = desktop_probe.set(True)
        try:
            assert tool() == 0
        finally:
            desktop_probe.reset(marker)
        assert snapshot(tmp_path)["events"] == []
        assert tool() == 1
        assert snapshot(tmp_path)["active_call_count"] == 0
        assert len(snapshot(tmp_path)["events"]) == 1
    finally:
        clear_sinks()


def test_snapshot_reads_bounded_redacted_tasks_and_counts_all_active(tmp_path: Path) -> None:
    store = TaskStore(tmp_path)
    for _ in range(55):
        item = store.create(task="token-here", executor="shell", cwd=str(tmp_path))
    store.write_logs(item["task_id"], stdout="x" * 20000 + "token-here Authorization: Bearer another-secret", stderr="token-here")
    result = snapshot(tmp_path, "token-here")
    assert result["active_task_count"] == 55
    assert len(result["tasks"]) == 50
    assert "token-here" not in json.dumps(result)
    assert "another-secret" not in json.dumps(result)
    assert len(result["tasks"][0]["stdout_tail"]) <= 4000


def test_snapshot_does_not_create_missing_state_or_follow_symlinks(tmp_path: Path) -> None:
    state = tmp_path / "missing"
    assert snapshot(state)["tasks"] == []
    assert not state.exists()
    (tmp_path / "tasks").symlink_to(tmp_path / "private", target_is_directory=True)
    assert snapshot(tmp_path)["tasks"] == []


def test_cancellation_kills_background_command_descendants(tmp_path: Path) -> None:
    store = TaskStore(tmp_path)
    registry = ExecutorRegistry(store=store, codex_command=None, claude_command=None)
    marker = tmp_path / "must-not-be-created"
    script = f"import time; from pathlib import Path; time.sleep(1); Path({str(marker)!r}).touch()"
    command = f"{shlex.quote(sys.executable)} -c {shlex.quote(script)} & wait"
    task = registry.submit_command(command=command, cwd=tmp_path, timeout=10)
    deadline = time.monotonic() + 3
    while task["task_id"] not in registry._processes and time.monotonic() < deadline:
        time.sleep(0.01)
    registry.cancel(task["task_id"])
    time.sleep(1.2)
    assert not marker.exists()
    assert store.get(task["task_id"])["status"] == "cancelled"


def test_shutdown_preserves_completed_task_status(tmp_path: Path) -> None:
    store = TaskStore(tmp_path)
    registry = ExecutorRegistry(store=store, codex_command=None, claude_command=None)
    task = registry.submit_command(command="true", cwd=tmp_path, timeout=5)
    registry.wait(task["task_id"], timeout=5)
    registry.shutdown()
    assert store.get(task["task_id"])["status"] == "succeeded"


def test_completed_shell_cleans_detached_output_descendants(tmp_path: Path) -> None:
    store = TaskStore(tmp_path)
    registry = ExecutorRegistry(store=store, codex_command=None, claude_command=None)
    marker = tmp_path / "must-not-outlive-task"
    script = f"import time; from pathlib import Path; time.sleep(0.7); Path({str(marker)!r}).touch()"
    task = registry.submit_command(
        command=f"{shlex.quote(sys.executable)} -c {shlex.quote(script)} >/dev/null 2>&1 &",
        cwd=tmp_path, timeout=5,
    )
    assert registry.wait(task["task_id"], timeout=5)["status"] == "succeeded"
    registry.shutdown()
    time.sleep(1)
    assert not marker.exists()
