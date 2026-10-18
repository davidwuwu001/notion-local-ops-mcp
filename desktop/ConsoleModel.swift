import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class ConsoleModel: ObservableObject {
    let runtime: RuntimeManager
    @Published var page: ConsolePage? = .overview
    @Published private(set) var inspection: ConsoleInspection?
    @Published private(set) var snapshot: ConsoleSnapshot?
    @Published private(set) var isChecking = false
    @Published private(set) var isActing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var startedAt: Date?
    @Published private(set) var workspaceRoot: String
    @Published var revealToken = false
    @Published var selectedTask: ConsoleTask?
    @Published var logText = "点击“刷新日志”查看最近的服务日志。"
    @Published var notice: String?
    private var polling: Task<Void, Never>?
    private var runtimeObserver: AnyCancellable?
    private var didStart = false
    private var quitting = false

    init(runtime: RuntimeManager) {
        self.runtime = runtime
        workspaceRoot = runtime.configuration.workspaceRoot
        runtimeObserver = runtime.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in
                guard let self, !self.runtime.isRunning else { return }
                self.inspection = nil
                self.startedAt = nil
            }
        }
    }

    var tools: [ConsoleTool] { inspection?.tools ?? [] }
    var events: [ConsoleEvent] { (snapshot?.events ?? []).reversed() }
    var tasks: [ConsoleTask] { snapshot?.tasks ?? [] }
    var activeTaskCount: Int { snapshot?.activeTaskCount ?? tasks.filter(\.isActive).count }
    var activeCallCount: Int { snapshot?.activeCallCount ?? 0 }
    var publicURL: String { inspection?.publicUrl ?? runtime.configuration.publicURL?.absoluteString ?? "未配置公网地址" }
    var tokenText: String { revealToken ? runtime.configuration.authToken : "••••••••••••••••••••••••" }
    var visibleError: String? { errorMessage ?? runtime.errorMessage }

    func start() async {
        guard !didStart else { return }
        didStart = true
        await performRuntime(.start)
        polling = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self else { return }
                if self.quitting { continue }
                await self.refreshSnapshot()
                tick += 1
                if tick % 7 == 0 && self.runtime.isRunning { await self.checkConnection() }
            }
        }
    }

    enum RuntimeAction { case start, stop, restart, tunnel }

    func performRuntime(_ action: RuntimeAction) async {
        guard !quitting, !isActing, !runtime.isBusy else { return }
        if action == .stop || action == .restart {
            guard await confirmAndCancelActiveTasks() else { return }
        }
        isActing = true
        errorMessage = nil
        inspection = nil
        defer { isActing = false }
        switch action {
        case .start: await runtime.start()
        case .stop: await runtime.stop()
        case .restart: await runtime.restart()
        case .tunnel: await runtime.restartTunnel()
        }
        if runtime.isRunning {
            if action != .tunnel { startedAt = Date() }
            await checkConnection()
        } else { startedAt = nil }
        await refreshSnapshot()
    }

    func checkConnection() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let value: ConsoleInspection = try await bridge("inspect")
            inspection = value
            checkedAt = Date()
            if let path = value.workspaceRoot { workspaceRoot = path }
            errorMessage = value.error.map(redact)
        } catch {
            inspection = nil
            checkedAt = Date()
            errorMessage = redact(error.localizedDescription)
        }
    }

    func refreshSnapshot() async {
        do {
            let value: ConsoleSnapshot = try await bridge("snapshot")
            guard value.success else { throw ConsoleError(value.error ?? "无法读取活动与任务记录。") }
            snapshot = value
            if let selectedTask { self.selectedTask = value.tasks?.first { $0.id == selectedTask.id } }
        } catch {
            snapshot = nil
            errorMessage = redact(error.localizedDescription)
        }
    }

    func cancelTask(_ task: ConsoleTask) async {
        guard !isActing else { return }
        isActing = true
        defer { isActing = false }
        do {
            try await cancel(task.id)
            notice = "已请求停止任务。"
            await refreshSnapshot()
        } catch { errorMessage = redact(error.localizedDescription) }
    }

    func chooseWorkspace() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "设为默认目录"
        panel.directoryURL = URL(fileURLWithPath: workspaceRoot)
        guard await panel.begin() == .OK, let url = panel.url else { return }
        isActing = true
        defer { isActing = false }
        do {
            let result: ConsoleActionResult = try await bridge("set-cwd", arguments: [url.path])
            guard result.success else { throw ConsoleError(result.error ?? "设置默认目录失败。") }
            try runtime.configuration.saveWorkspaceRoot(url.path)
            workspaceRoot = url.path
            notice = "默认目录已保存。它用于相对路径解析，不限制文件访问权限。"
        } catch { errorMessage = redact(error.localizedDescription) }
    }

    func copy(_ text: String, notice message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = message
    }

    func loadLogs() async {
        let directory = runtime.configuration.logsDirectory
        let token = runtime.configuration.authToken
        logText = await Task.detached(priority: .utility) {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
                var sections: [String] = []
                let recent = files.sorted {
                    let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return left > right
                }
                for file in recent.prefix(8) {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    let length = try handle.seekToEnd()
                    try handle.seek(toOffset: length > 16_384 ? length - 16_384 : 0)
                    let data = try handle.read(upToCount: 16_384) ?? Data()
                    sections.append("[\(file.lastPathComponent)]\n\(String(decoding: data, as: UTF8.self))")
                }
                let text = sections.isEmpty ? "暂无日志。" : sections.joined(separator: "\n\n")
                return token.isEmpty ? text : text.replacingOccurrences(of: token, with: "[已隐藏 Token]")
            } catch { return "读取日志失败：\(error.localizedDescription)" }
        }.value
    }

    func requestQuit() async -> Bool {
        guard !quitting else { return false }
        quitting = true
        if isActing || runtime.isBusy { notice = "正在等待当前操作收尾，随后安全退出…" }
        while isActing || runtime.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
        if runtime.isRunning {
            guard await confirmAndCancelActiveTasks() else {
                quitting = false
                notice = nil
                return false
            }
        }
        polling?.cancel()
        await runtime.stop()
        if runtime.isRunning {
            quitting = false
            errorMessage = runtime.errorMessage ?? "服务仍在停止，请稍后重试退出。"
            return false
        }
        return true
    }

    private func confirmAndCancelActiveTasks() async -> Bool {
        await refreshSnapshot()
        guard snapshot?.success == true else {
            errorMessage = "无法确认后台任务状态，请重试后再停止服务或退出。"
            return confirmShutdownAfterFailure("无法读取任务状态。停止后会尝试结束本 App 启动的服务和任务。")
        }
        guard activeTaskCount + activeCallCount > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "还有任务正在执行"
        alert.informativeText = "当前有 \(activeTaskCount) 个后台任务、\(activeCallCount) 个工具调用。停止服务将取消后台任务，并等待正在执行的调用收尾。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续运行")
        alert.addButton(withTitle: "停止任务")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        do {
            for task in tasks where task.isActive { try await cancel(task.id) }
            return true
        } catch {
            errorMessage = redact(error.localizedDescription)
            return confirmShutdownAfterFailure("任务取消接口未成功。仍可停止本 App 启动的服务，由服务退出流程清理任务。")
        }
    }

    private func confirmShutdownAfterFailure(_ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "任务状态检查未完成"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续运行")
        alert.addButton(withTitle: "仍然停止自有服务")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func cancel(_ id: String) async throws {
        let result: ConsoleActionResult = try await bridge("cancel", arguments: [id])
        guard result.success else { throw ConsoleError(result.error ?? "停止任务失败。") }
    }

    private func redact(_ text: String) -> String {
        let token = runtime.configuration.authToken
        return token.isEmpty ? text : text.replacingOccurrences(of: token, with: "[已隐藏 Token]")
    }

    private func bridge<T: Decodable>(_ action: String, arguments: [String] = []) async throws -> T {
        let data = try await ConsoleBridge.run(configuration: runtime.configuration, workspaceRoot: workspaceRoot, action: action, arguments: arguments)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ConsoleError("后台返回的数据无法解析，请查看服务日志。") }
    }
}

private struct ConsoleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum ConsoleBridge {
    static func run(configuration: RuntimeConfiguration, workspaceRoot: String, action: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = configuration.pythonURL
                process.arguments = ["-m", "notion_local_ops_mcp.desktop_bridge", action] + arguments
                process.currentDirectoryURL = configuration.repositoryURL
                var environment = configuration.environment
                environment["NOTION_LOCAL_OPS_WORKSPACE_ROOT"] = workspaceRoot
                process.environment = environment
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    let timeout = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            }
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
                    defer { timeout.cancel(); try? output.fileHandleForReading.close() }
                    var data = Data()
                    while let part = try output.fileHandleForReading.read(upToCount: 8192), !part.isEmpty {
                        guard data.count + part.count <= 4_194_304 else {
                            process.terminate()
                            throw ConsoleError("后台返回内容超过安全显示上限。")
                        }
                        data.append(part)
                    }
                    process.waitUntilExit()
                    guard !data.isEmpty else {
                        throw ConsoleError(process.terminationReason == .uncaughtSignal ? "后台检查超时或意外退出，请重试。" : "后台未返回数据，请检查 Python 环境与日志。")
                    }
                    continuation.resume(returning: data)
                } catch {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                        process.waitUntilExit()
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
