from __future__ import annotations

import asyncio
import json
from pathlib import Path
import shlex
import sys
import time

import pytest
import httpx

from notion_local_ops_mcp import desktop_bridge as bridge
from notion_local_ops_mcp.desktop_monitor import DesktopMonitor, snapshot
from notion_local_ops_mcp.instrument import clear_sinks, register_sink
from test_mcp_local_simulation import _running_server, _mcp_session, _call_tool


def test_public_url_uses_existing_cloudflare_yaml(tmp_path: Path, monkeypatch) -> None:
    yaml = tmp_path / "cloudflared.yml"
    yaml.write_text("ingress:\n  - hostname: 'mcp.example.com'\n    service: http://127.0.0.1:8766\n  - service: http_status:404\n")
    monkeypatch.setenv("NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG", str(yaml))
    assert bridge.public_url() == "https://mcp.example.com/mcp"


@pytest.mark.parametrize("status, phrase", [(401, "认证失败"), (530, "隧道尚未连通"), (502, "隧道尚未连通")])
def test_connection_errors_are_actionable_without_http_trace(status: int, phrase: str) -> None:
    response = httpx.Response(status, request=httpx.Request("POST", "https://mcp.example.test/mcp"))
    try:
        response.raise_for_status()
    except httpx.HTTPStatusError as error:
        message = bridge._error(error)
    assert phrase in message and str(status) in message
    assert "developer.mozilla" not in message


def test_invalid_actions_fail_before_network(tmp_path: Path) -> None:
    for action, args in (("cancel", ["../../secret"]), ("set-cwd", ["relative"]), ("set-cwd", [str(tmp_path / "missing")]), ("invalid", [])):
        with pytest.raises(ValueError):
            asyncio.run(bridge.dispatch(action, args))


def test_bridge_cli_emits_only_one_json_error(monkeypatch, capsys) -> None:
    monkeypatch.setattr(bridge.config, "AUTH_TOKEN", "private-token")

    async def failure(*args):
        raise ValueError("Bearer private-token")

    monkeypatch.setattr(bridge, "dispatch", failure)
    with pytest.raises(SystemExit) as error:
        bridge.main(["inspect"])
    assert error.value.code == 1
    out = capsys.readouterr().out
    assert out.count("\n") == 1
    assert json.loads(out)["success"] is False
    assert "private-token" not in out


def test_inspect_preserves_local_info_when_public_fails(monkeypatch) -> None:
    monkeypatch.setattr(bridge, "public_url", lambda: "https://unavailable.example/mcp")
    monkeypatch.setattr(bridge.config, "AUTH_TOKEN", "sample-token")

    async def request(url, **kwargs):
        if url.startswith("https"):
            raise TimeoutError("公网连接超时")
        return {"success": True, "auth": "shared_token", "workspace_root": "/tmp/project", "desktop_tools": [{"name": "real-tool", "description": "description"}]}

    monkeypatch.setattr(bridge, "_bounded_request", request)
    result = asyncio.run(bridge.inspect())
    assert result["local_ok"] and result["auth_ok"]
    assert result["success"] is False and result["public_ok"] is False
    assert result["tools"][0]["name"] == "real-tool"
    assert result["workspace_root"] == "/tmp/project"


def test_real_mcp_probe_is_not_client_activity_and_cwd_works(tmp_path: Path, monkeypatch) -> None:
    from notion_local_ops_mcp import session as session_state

    monkeypatch.setattr(session_state, "_default_cwd", None)
    clear_sinks()
    monitor = DesktopMonitor(tmp_path / "state")
    register_sink(monitor)
    monkeypatch.setattr(bridge.config, "AUTH_TOKEN", "desktop-test")
    try:
        with _running_server(tmp_path, monkeypatch, auth_token="desktop-test") as url:
            monkeypatch.setattr(bridge, "local_url", lambda: url)

            async def scenario():
                data = await bridge._bounded_request(url, listing=True)
                assert data["success"] is True
                assert data["desktop_tools"]
                assert snapshot(tmp_path / "state")["events"] == []
                result = await bridge.dispatch("set-cwd", [str(tmp_path)])
                assert result["workspace_root"] == str(tmp_path)
                assert snapshot(tmp_path / "state")["events"] == []
                async with _mcp_session(url, token="desktop-test") as session:
                    await _call_tool(session, "server_info", {})
                assert len(snapshot(tmp_path / "state")["events"]) == 1
                assert snapshot(tmp_path / "state")["active_call_count"] == 0

            asyncio.run(scenario())
    finally:
        clear_sinks()


def test_cancel_calls_existing_tool_and_rejects_failure(monkeypatch) -> None:
    calls = []

    async def request(url, **kwargs):
        calls.append(kwargs)
        return {"cancelled": True}

    monkeypatch.setattr(bridge, "_bounded_request", request)
    assert asyncio.run(bridge.dispatch("cancel", ["abcdef012345"]))["success"]
    assert calls == [{"tool": "cancel_task", "arguments": {"task_id": "abcdef012345"}}]


def test_asgi_shutdown_cleans_up_owned_task_groups(tmp_path: Path, monkeypatch) -> None:
    marker = tmp_path / "must-not-exist"
    script = f"import time; from pathlib import Path; time.sleep(1); Path({str(marker)!r}).touch()"
    with _running_server(tmp_path, monkeypatch, auth_token="desktop-test") as url:
        async def scenario():
            async with _mcp_session(url, token="desktop-test") as session:
                task = await _call_tool(session, "run_command_stream", {
                    "command": f"{shlex.quote(sys.executable)} -c {shlex.quote(script)} & wait",
                    "timeout": 10,
                })
                return task["task_id"]
        task_id = asyncio.run(scenario())
    time.sleep(1.2)
    assert not marker.exists()
    meta = json.loads((tmp_path / "state" / "tasks" / task_id / "meta.json").read_text())
    assert meta["status"] == "cancelled"
