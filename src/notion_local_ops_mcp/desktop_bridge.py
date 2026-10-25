"""One JSON response per invocation, with credentials supplied only via env."""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import re
import sys

import httpx
from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client

from . import config
from .desktop_monitor import TASK_ID, redact, snapshot
from .executors import _command_available


def public_url() -> str | None:
    explicit = os.environ.get("NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG") or os.environ.get("CLOUDFLARED_CONFIG")
    candidates = [Path(explicit).expanduser()] if explicit else [Path.cwd() / "cloudflared.local.yml", Path.cwd() / "cloudflared.local.yaml"]
    for path in candidates:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        match = re.search(r"(?m)^\s*(?:-\s*)?hostname:\s*['\"]?([a-zA-Z0-9.-]+)['\"]?\s*(?:#.*)?$", text)
        if match:
            return f"https://{match.group(1)}/mcp"
    if config.PUBLIC_BASE_URL:
        return config.PUBLIC_BASE_URL.rstrip("/") + "/mcp"
    return None


def local_url() -> str:
    host = config.HOST
    if ":" in host:
        host = f"[{host}]"
    return f"http://{host}:{config.PORT}/mcp"


async def _request(url: str, tool: str = "server_info", arguments: dict | None = None, *, listing: bool = False) -> dict:
    headers = {"X-Local-Ops-Desktop": "1"}
    if config.AUTH_TOKEN:
        headers["Authorization"] = f"Bearer {config.AUTH_TOKEN}"
    async with httpx.AsyncClient(headers=headers, timeout=6, trust_env=False) as client:
        async with streamable_http_client(url, http_client=client) as (reader, writer):
            async with ClientSession(reader, writer) as session:
                await session.initialize()
                result = await session.call_tool(tool, arguments or {})
                if result.is_error:
                    raise RuntimeError("MCP 工具调用失败")
                data = result.structured_content
                if data is None:
                    data = next((json.loads(block.text) for block in result.content if getattr(block, "type", None) == "text"), {})
                if not isinstance(data, dict):
                    raise RuntimeError("MCP 返回数据格式错误")
                if listing:
                    tools = await session.list_tools()
                    data["desktop_tools"] = [{"name": item.name, "description": item.description or ""} for item in tools.tools]
                return data


async def _bounded_request(url: str, **kwargs) -> dict:
    return await asyncio.wait_for(_request(url, **kwargs), timeout=10)


def _error(exc: BaseException) -> str:
    if isinstance(exc, BaseExceptionGroup):
        return "; ".join(_error(child) for child in exc.exceptions)[:500]
    if isinstance(exc, httpx.HTTPStatusError):
        status = exc.response.status_code
        if status == 401:
            return "认证失败（HTTP 401），请检查接入 Token。"
        if status in {502, 503, 530}:
            return f"Cloudflare 隧道尚未连通（HTTP {status}），请检查网络或重新连接隧道。"
        return f"服务返回 HTTP {status}，请查看诊断日志。"
    if isinstance(exc, (TimeoutError, httpx.TimeoutException)):
        return "连接检查超时，请确认服务与网络可用。"
    return redact(str(exc) or type(exc).__name__, config.AUTH_TOKEN)[:500]


async def inspect() -> dict:
    url = public_url()
    result = {
        "success": False, "local_ok": False, "public_ok": False, "auth_ok": False,
        "tools": [], "codex_available": _command_available(config.CODEX_COMMAND),
        "claude_available": _command_available(config.CLAUDE_COMMAND),
        "workspace_root": str(config.WORKSPACE_ROOT), "public_url": url,
    }
    urls = [local_url()] + ([url] if url else [])
    responses = await asyncio.gather(*(_bounded_request(address, listing=index == 0) for index, address in enumerate(urls)), return_exceptions=True)
    errors = []
    for index, response in enumerate(responses):
        label = "local_ok" if index == 0 else "public_ok"
        if isinstance(response, BaseException):
            errors.append(("本地：" if index == 0 else "公网：") + _error(response))
        elif response.get("success") is True:
            result[label] = True
            if index == 0:
                result["tools"] = response.get("desktop_tools", [])
                result["workspace_root"] = response.get("session_cwd") or response.get("workspace_root") or result["workspace_root"]
                result["auth_ok"] = bool(config.AUTH_TOKEN) and response.get("auth") in {"shared_token", "oauth"}
    result["success"] = result["local_ok"] and result["public_ok"]
    if not url:
        errors.append("未找到 Cloudflare 公网域名配置")
    if errors:
        result["error"] = "；".join(errors)
    return result


async def dispatch(action: str, arguments: list[str]) -> dict:
    if action == "snapshot" and not arguments:
        return snapshot(config.STATE_DIR, config.AUTH_TOKEN)
    if action == "inspect" and not arguments:
        return await inspect()
    if action == "cancel" and len(arguments) == 1:
        if not TASK_ID.fullmatch(arguments[0]):
            raise ValueError("任务 ID 格式无效")
        data = await _bounded_request(local_url(), tool="cancel_task", arguments={"task_id": arguments[0]})
        return {"success": data.get("cancelled") is True, "error": data.get("error")}
    if action == "set-cwd" and len(arguments) == 1:
        path = Path(arguments[0]).expanduser()
        if not path.is_absolute() or not path.is_dir():
            raise ValueError("请选择存在的绝对目录")
        data = await _bounded_request(local_url(), tool="set_default_cwd", arguments={"path": str(path.resolve())})
        return {"success": data.get("success") is True, "workspace_root": data.get("session_cwd"), "error": data.get("error")}
    raise ValueError("支持 inspect、snapshot、cancel <task_id>、set-cwd <absolute_path>")


def main(argv: list[str] | None = None) -> None:
    args = sys.argv[1:] if argv is None else argv
    try:
        if not args:
            raise ValueError("缺少操作名称")
        result = asyncio.run(dispatch(args[0], args[1:]))
    except Exception as exc:
        result = {"success": False, "error": _error(exc)}
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0 if result.get("success") else 1)


if __name__ == "__main__":
    main()
