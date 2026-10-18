import SwiftUI

struct ConsoleView: View {
    @ObservedObject var model: ConsoleModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28)).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本地 MCP").font(.headline)
                        Text("你的 Mac，随时连接").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 22)
                List(ConsolePage.allCases, selection: $model.page) { page in
                    Label(page.rawValue, systemImage: page.symbol).tag(page)
                        .padding(.vertical, 5)
                }
                .listStyle(.sidebar)
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    Circle().fill(model.runtime.isRunning ? Color.teal : Color.secondary).frame(width: 7, height: 7)
                    Text(model.runtime.isRunning ? "服务运行中" : "服务已停止").font(.caption)
                }
                .foregroundStyle(.secondary).padding(18)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let error = model.visibleError {
                        message(error, symbol: "exclamationmark.triangle.fill", color: .orange)
                    }
                    if let notice = model.notice {
                        HStack {
                            message(notice, symbol: "checkmark.circle.fill", color: .teal)
                            Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }
                    }
                    switch model.page ?? .overview {
                    case .overview: overview
                    case .tools: toolsAndTasks
                    case .settings: settings
                    }
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 650)
        .tint(.teal)
        .sheet(item: $model.selectedTask) { task in taskDetail(task) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text((model.page ?? .overview).rawValue).font(.system(size: 28, weight: .bold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if model.runtime.isBusy || model.isActing || model.isChecking { ProgressView().controlSize(.small).padding(.top, 9) }
            Button { Task { await model.checkConnection() } } label: {
                Label("检查连接", systemImage: "arrow.clockwise")
            }
            .disabled(model.isChecking || model.runtime.isBusy)
        }
    }

    private var subtitle: String {
        switch model.page ?? .overview {
        case .overview: return "查看服务状态，管理你的本地连接。"
        case .tools: return "实际提供的工具，以及正在执行的后台任务。"
        case .settings: return "管理接入信息、默认目录和诊断日志。"
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                statusCard("本地服务", symbol: "desktopcomputer", state: model.inspection?.localOk,
                           detail: model.runtime.configuration.localURL.absoluteString)
                statusCard("公网连接", symbol: "network", state: model.inspection?.publicOk,
                           detail: "Cloudflare 固定地址")
                statusCard("MCP 鉴权", symbol: "lock.shield", state: model.inspection?.authOk,
                           detail: "实际验证 Bearer Token")
            }
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("运行控制").font(.headline)
                        if let started = model.startedAt {
                            Text("本次启动于 \(started.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("打开 App 自动启动，关闭 App 停止服务。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.runtime.isRunning {
                        Button("重启服务") { Task { await model.performRuntime(.restart) } }
                        Button("重新连接隧道") { Task { await model.performRuntime(.tunnel) } }
                        Button("停止服务", role: .destructive) { Task { await model.performRuntime(.stop) } }
                    } else {
                        Button("启动服务") { Task { await model.performRuntime(.start) } }.buttonStyle(.borderedProminent)
                    }
                }
                .disabled(model.isActing || model.runtime.isBusy)
            }
            card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Notion 接入地址", systemImage: "link").font(.headline)
                        Text(model.publicURL).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text("最近检查：\(model.checkedAt?.formatted(date: .omitted, time: .standard) ?? "尚未检查")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("复制地址") { model.copy(model.publicURL, notice: "接入地址已复制。") }
                        .disabled(model.runtime.configuration.publicURL == nil)
                }
            }
            HStack(spacing: 12) {
                metric("可用工具", value: "\(model.tools.count)", symbol: "wrench.and.screwdriver")
                metric("活动任务", value: "\(model.activeTaskCount)", symbol: "play.circle")
                metric("最近客户端活动", value: consoleDate(model.snapshot?.lastActivityAt), symbol: "clock")
            }
            activity
        }
    }

    private func statusCard(_ title: String, symbol: String, state: Bool?, detail: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: symbol).font(.title3).foregroundStyle(.secondary); Spacer(); statusDot(state) }
                Text(title).font(.headline)
                Text(state == true ? "连接正常" : state == false ? "连接异常" : model.isChecking ? "正在检查…" : "尚未验证")
                    .font(.title3.weight(.semibold)).foregroundStyle(state == true ? .teal : state == false ? .orange : .secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 30, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
                Text(value).font(title == "最近客户端活动" ? .subheadline : .title2.weight(.semibold)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
        }
    }

    private var activity: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("最近活动").font(.headline); Spacer(); Text("App 健康检查不计入活动").font(.caption).foregroundStyle(.secondary) }
                if model.events.isEmpty {
                    empty("还没有工具调用", detail: "客户端调用工具后，这里会出现时间、结果和耗时。", symbol: "waveform.path")
                } else {
                    ForEach(Array(model.events.prefix(15))) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: event.ok == true ? "checkmark.circle.fill" : event.ok == false ? "exclamationmark.circle.fill" : "clock")
                                .foregroundStyle(event.ok == false ? .orange : .teal)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title ?? event.tool).font(.system(.body, design: .monospaced))
                                if let error = event.error, !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(consoleDate(event.startedAt)).font(.caption).foregroundStyle(.secondary)
                                if let duration = event.durationMs { Text(String(format: "%.0f ms", duration)).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        if event.id != model.events.prefix(15).last?.id { Divider() }
                    }
                }
                Text("共享 Token 无法区分具体 Notion 账号；这里表示最近实际调用。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var toolsAndTasks: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                executor("Codex CLI", available: model.inspection?.codexAvailable)
                executor("Claude CLI", available: model.inspection?.claudeAvailable)
            }
            card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("后台任务").font(.headline); Spacer(); Button("刷新") { Task { await model.refreshSnapshot() } } }
                    if model.tasks.isEmpty {
                        empty("暂无后台任务", detail: "后台命令和 AI 委派任务会出现在这里。", symbol: "tray")
                    } else {
                        ForEach(model.tasks) { task in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: task.isActive ? "play.circle.fill" : "checklist").foregroundStyle(task.isActive ? .teal : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.task ?? task.id).lineLimit(2)
                                    Text("\(task.executor ?? "命令") · \(task.id) · \(consoleDate(task.updatedAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(task.statusTitle).font(.caption).foregroundStyle(task.isActive ? .teal : .secondary)
                                Button("查看输出") { model.selectedTask = task }
                                if task.isActive {
                                    Button("停止", role: .destructive) { Task { await model.cancelTask(task) } }.disabled(model.isActing)
                                }
                            }
                            if task.id != model.tasks.last?.id { Divider() }
                        }
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("工具清单").font(.headline); Spacer(); Text("\(model.tools.count) 个 · 来自实际 MCP 服务").font(.caption).foregroundStyle(.secondary) }
                    if model.tools.isEmpty {
                        empty("尚未获取工具", detail: "启动服务并检查连接后，将显示动态工具清单。", symbol: "wrench.and.screwdriver")
                    } else {
                        ForEach(["文件与搜索", "Git", "命令", "任务", "连接与配置"], id: \.self) { category in
                            let tools = model.tools.filter { $0.category == category }
                            if !tools.isEmpty {
                                Text(category).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(tools) { tool in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(tool.chineseTitle).fontWeight(.medium); Text(tool.name).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                                        if let description = tool.description { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func executor(_ name: String, available: Bool?) -> some View {
        card {
            HStack { Image(systemName: "terminal").foregroundStyle(.teal); Text(name).fontWeight(.medium); Spacer(); Text(available == true ? "可用" : available == false ? "未找到" : "未检查").foregroundStyle(.secondary).font(.caption) }
                .frame(maxWidth: .infinity)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 16) {
                    Text("连接配置").font(.headline)
                    LabeledContent("接入地址") { Text(model.publicURL).textSelection(.enabled) }
                    LabeledContent("认证方式", value: "Bearer Token")
                    Divider()
                    HStack {
                        Text(model.tokenText).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button(model.revealToken ? "隐藏" : "显示") { model.revealToken.toggle() }
                        Button("复制 Token") { model.copy(model.runtime.configuration.authToken, notice: "Token 已复制到剪贴板。") }
                    }
                    Text("持有 Token 的客户端拥有这套 MCP 的文件与命令工具权限。").font(.caption).foregroundStyle(.secondary)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("默认工作目录").font(.headline); Spacer(); Button("选择文件夹…") { Task { await model.chooseWorkspace() } }.disabled(model.isActing || !model.runtime.isRunning) }
                    Text(model.workspaceRoot).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Label("这是相对路径的起点，不是沙箱或文件权限限制。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("诊断日志").font(.headline)
                        Spacer()
                        Button("打开日志文件夹") { NSWorkspace.shared.open(model.runtime.configuration.logsDirectory) }
                        Button("刷新日志") { Task { await model.loadLogs() } }
                    }
                    Text("仅显示最近日志，已隐藏已知 Token。").font(.caption).foregroundStyle(.secondary)
                    ScrollView([.horizontal, .vertical]) {
                        Text(model.logText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                    }
                    .frame(height: 260).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func taskDetail(_ task: ConsoleTask) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("任务输出").font(.title2.bold()); Spacer(); Text(task.statusTitle).foregroundStyle(.secondary); Button("完成") { model.selectedTask = nil } }
            Text(task.task ?? task.id).lineLimit(4).textSelection(.enabled)
            Text("\(task.id) · \(task.cwd ?? "未记录目录")").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("标准输出").font(.headline)
                    Text((task.stdoutTail?.isEmpty == false ? task.stdoutTail : nil) ?? (task.isActive ? "任务运行中，输出将在完成后更新。" : "暂无输出"))
                    if let stderr = task.stderrTail, !stderr.isEmpty { Text("错误输出").font(.headline); Text(stderr).foregroundStyle(.orange) }
                }
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Text("任务状态定期刷新；输出保留最近一段，通常在任务完成后更新。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 760, height: 540)
    }

    private func statusDot(_ state: Bool?) -> some View {
        Circle().fill(state == true ? Color.teal : state == false ? Color.orange : Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.callout).foregroundStyle(color).textSelection(.enabled)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
