# macOS 控制台 MVP 开发约定

## 范围

独立原生 macOS App「本地 MCP 控制台」，三个页面：总览、工具与任务、设置与诊断。复用本仓库 MCP、任务记录、instrument 工具调用事件及既有 Cloudflare 配置。使用系统 SwiftUI/AppKit、Foundation 和现有 Python 依赖，不新增前端框架。不自动提交或推送。现有公网地址和 Token 不变。

打开自动启动本地 MCP supervisor 和隧道；最小化保持运行；关闭窗口与 Cmd-Q 退出并停止所拥有的进程，有活动任务时先确认取消与退出。若端口由其他进程占用，报告冲突；不得杀死或冒领已有服务。原 LaunchAgent 切换由主代理在集成后执行，开发代理不能修改现有服务或本机 env。

## 所有权

- Python 代理：`src/notion_local_ops_mcp/desktop_bridge.py`、`desktop_monitor.py`、`server.py` 必要接入、`executors.py` 必要进程收尾、相应 `tests/test_desktop_*.py`。禁止编辑其他代理 Swift、打包脚本、文档。
- UI 代理：`desktop/ConsoleView.swift`、`desktop/ConsoleModel.swift`、可选 `desktop/ConsoleTypes.swift`。不得修改 Runtime.swift、入口、打包、Python。
- 生命周期代理：`desktop/Runtime.swift`、`desktop/ConsoleApp.swift`、`scripts/build-desktop.sh`、`scripts/install-desktop.sh`、`desktop/` 图标生成与 plist 模板、`tests/desktop/` 生命周期自测。不得修改 UI 或 Python。
- 主代理：接口协调、文档、集成修正、独立审查、构建/安装/服务迁移与实际 App 验收。对所有权交界先沟通。

所有代理共享工作区。不可撤销他人改动；仅使用 apply_patch 修改文件。运行测试使用隔离临时目录，不能执行真实 AI 委托或真实用户项目改写。

## Python / UI 桥接协议

原生 App 使用 Process 执行 `<repo>/.venv/bin/python -m notion_local_ops_mcp.desktop_bridge <action> [args]`，cwd 为仓库，环境由 RuntimeConfiguration 读取 env 后提供。stdout 恰为一个 JSON 对象（日志只去 stderr），错误也返回 JSON 和非零退出码。不得将 Token 放入命令行参数或打印。

动作：

- `inspect`：通过真实 MCP 客户端访问本地 MCP 和公共 MCP，确认 initialize、鉴权工具调用，不执行写操作；返回 `{success,local_ok,public_ok,auth_ok,tools:[{name,description}],codex_available,claude_available,workspace_root,public_url,error?}`。公网 URL 从现有 cloudflared yaml 提取，不硬编码机器地址；超时需有界。健康探测用专用 HTTP header `X-Local-Ops-Desktop: 1` 标记，不计入用户活动。失败保留可获得的本地信息。
- `snapshot`：轻量标准库读取观测文件和任务元数据，不连接外部网络，返回 `{success,events:[{id,tool,title,started_at,duration_ms,ok,error?}],tasks:[{task_id,task,executor,cwd,status,created_at,updated_at,stdout_tail,stderr_tail}],last_activity_at?,active_task_count}`；最多返回最近 100 个事件、50 个任务，文本有界。不可将 `.env`、认证头、文件/patch/命令正文写入活动日志。任务输出仅用于本地 UI 显示，尽可能对已知本机 Token 脱敏。
- `cancel <task_id>`：通过本地 MCP 调用既有 cancel_task，校验任务 ID，返回 `{success,error?}`。
- `set-cwd <absolute_path>`：检查目录存在，通过既有工具修改运行时默认 cwd，返回 `{success,workspace_root,error?}`；持久化由主代理/Runtime 配置保存统一处理。

`desktop_monitor.py` 复用 instrument 的 sink；仅 App 显式设置 `NOTION_LOCAL_OPS_DESKTOP_MONITOR=1` 时启用。事件本地持久化，状态目录 700、文件 600，有界；不要向公网增加管理接口。需要只读请求标记时可在现有 HTTP 层用 ContextVar 传播，保持测试兼容。工具清单以实际 MCP list_tools 返回值为准，不硬编码 24。

## Swift 模块边界

`Runtime.swift` 提供：

```swift
struct RuntimeConfiguration {
    let repositoryURL: URL
    let pythonURL: URL
    let cloudflaredURL: URL
    let stateDirectory: URL
    let logsDirectory: URL
    let environment: [String: String]
    let localURL: URL
    let publicURL: URL?
    let workspaceRoot: String
    let authToken: String
    static func load() throws -> RuntimeConfiguration
    func saveWorkspaceRoot(_ path: String) throws
}

@MainActor final class RuntimeManager: ObservableObject {
    @Published private(set) var isRunning: Bool
    @Published private(set) var isBusy: Bool
    @Published private(set) var errorMessage: String?
    let configuration: RuntimeConfiguration
    init(configuration: RuntimeConfiguration)
    func start() async
    func stop() async
    func restart() async
    func restartTunnel() async
}
```

以上字段用清晰相同名字实现，若更改接口须通知其他代理。进程启动、管道读写/等待不能阻塞主线程；启动失败要清理自己的部分启动，停止有界并终止自有子进程组。不能把 env Token 写入日志。ConsoleApp 创建 Configuration/Runtime/ConsoleModel，显示 ConsoleView(model: model)。

网络恢复补充（2026-10-19）：`NOTION_LOCAL_OPS_TUNNEL_DIRECT=1` 显式启用仅隧道物理 IPv4 出口，由 SystemConfiguration 读取主 `en*` 接口当前地址；原 init 调用保持兼容。地址变化自动重连；已运行服务的隧道失败不能调用全量 cleanup，必须保留 supervisor/任务并间隔 10 秒重试。只有 supervisor 退出、用户停止或首次整体启动失败才整体收尾。不自动修改系统代理、路由、VPN 或云端 DNS。

`ConsoleModel.swift` 提供 `@MainActor final class ConsoleModel: ObservableObject`，`init(runtime: RuntimeManager)`，持有 `runtime`，自动刷新和状态/桥接动作；`func requestQuit() async -> Bool`：若有活动任务，提示取消并退出或继续运行；用户确认后 cancel/stop，并返回是否可退出。App 入口处理 applicationShouldTerminate、红色关闭按钮，await 此方法后真正退出。打开时 `model.start()`，或 UI .task 调用，双方约定只调用一次。模型支持 `func start() async`。视图直接 `@ObservedObject var model`，Runtime 状态要能触发 UI 更新。

原生 UI 采用中文，连接/鉴权/最近客户端活动各自表达实际证据；默认目录显眼标注不是权限限制。Token 默认隐藏，显示/复制必须由用户点击。不将 App 自己的轮询当作 Notion 已连接。

## 验证门

Python：新增观测、脱敏、排除探测、桥接错误及取消路径测试；保持原测试通过。
Swift：编译成功，提供隔离 fake 子进程生命周期自检；真实 App 验收由主代理执行。
交付需包含独立图标、稳定 bundle ID `local.notion-ops.console`、产物 `dist/本地 MCP 控制台.app`、可恢复安装。不要覆写其他 App 或创建云端资源。
