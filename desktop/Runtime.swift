import Foundation
import Combine
import Darwin
import SystemConfiguration

enum RuntimeFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

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

    static func load() throws -> RuntimeConfiguration {
        let override = ProcessInfo.processInfo.environment["NOTION_LOCAL_OPS_DESKTOP_REPOSITORY"]
        guard let path = override ?? Bundle.main.object(forInfoDictionaryKey: "LocalOpsRepository") as? String else {
            throw RuntimeFailure.message("未找到项目目录，请重新构建控制台。")
        }
        return try load(repositoryURL: URL(fileURLWithPath: path))
    }

    static func load(repositoryURL: URL, logsDirectory: URL? = nil) throws -> RuntimeConfiguration {
        let repositoryURL = repositoryURL.standardizedFileURL
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let envURL = repositoryURL.appendingPathComponent(".env")
        let text = try String(contentsOf: envURL, encoding: .utf8)
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let assignment = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
            guard let separator = assignment.firstIndex(of: "=") else { continue }
            let key = String(assignment[..<separator]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z_][A-Za-z_0-9]*$", options: .regularExpression) != nil else { continue }
            environment[key] = try envValue(String(assignment[assignment.index(after: separator)...]), environment: environment)
        }
        environment["NOTION_LOCAL_OPS_DESKTOP_MONITOR"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        let home = FileManager.default.homeDirectoryForCurrentUser
        func resolve(_ value: String) -> URL {
            let expanded = (value as NSString).expandingTildeInPath
            return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : repositoryURL.appendingPathComponent(expanded)
        }
        let host = environment["NOTION_LOCAL_OPS_HOST"] ?? "127.0.0.1"
        guard host == "127.0.0.1" || host == "localhost" else { throw RuntimeFailure.message("控制台要求服务仅监听本机 127.0.0.1。") }
        guard let port = Int(environment["NOTION_LOCAL_OPS_PORT"] ?? "8766"), (1...65535).contains(port) else {
            throw RuntimeFailure.message("本地端口配置无效。")
        }
        let token = environment["NOTION_LOCAL_OPS_AUTH_TOKEN"] ?? ""
        guard !token.isEmpty else { throw RuntimeFailure.message("缺少 MCP Bearer Token，请检查项目 .env。") }
        let configURL = resolve(environment["NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG"] ?? "cloudflared.local.yml")
        environment["NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG"] = configURL.path
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        var publicURL: URL?
        for line in yaml.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)
            if value.hasPrefix("hostname:") {
                let hostname = value.dropFirst(9).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                guard hostname.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { continue }
                publicURL = URL(string: "https://\(hostname)/mcp")
                break
            }
        }
        let cloudflared = (environment["PATH"] ?? "").components(separatedBy: ":").map { URL(fileURLWithPath: $0).appendingPathComponent("cloudflared") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let cloudflared else { throw RuntimeFailure.message("找不到 cloudflared，请检查 PATH。") }
        let python = repositoryURL.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw RuntimeFailure.message("找不到项目 Python 虚拟环境。") }
        let workspace = environment["NOTION_LOCAL_OPS_WORKSPACE_ROOT"] ?? repositoryURL.path
        environment["NOTION_LOCAL_OPS_WORKSPACE_ROOT"] = workspace
        let state = resolve(environment["NOTION_LOCAL_OPS_STATE_DIR"] ?? home.appendingPathComponent(".notion-local-ops-mcp").path)
        environment["NOTION_LOCAL_OPS_STATE_DIR"] = state.path
        return RuntimeConfiguration(repositoryURL: repositoryURL, pythonURL: python, cloudflaredURL: cloudflared, stateDirectory: state,
            logsDirectory: logsDirectory ?? home.appendingPathComponent("Library/Logs/notion-local-ops-mcp"), environment: environment,
            localURL: URL(string: "http://127.0.0.1:\(port)/mcp")!, publicURL: publicURL, workspaceRoot: workspace, authToken: token)
    }

    // Parse assignments without executing shell expressions from a configuration file.
    static func envValue(_ raw: String, environment: [String: String]) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("'") {
            guard value.hasSuffix("'"), value.count >= 2 else { throw RuntimeFailure.message(".env 单引号不完整。") }
            return String(value.dropFirst().dropLast())
        }
        var source = value
        if value.hasPrefix("\"") {
            guard value.hasSuffix("\""), value.count >= 2 else { throw RuntimeFailure.message(".env 双引号不完整。") }
            source = String(value.dropFirst().dropLast())
        }
        let chars = Array(source)
        var output = "", index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count {
                output.append(chars[index + 1]); index += 2; continue
            }
            if chars[index] == "`" || (chars[index] == "$" && index + 1 < chars.count && chars[index + 1] == "(") {
                throw RuntimeFailure.message(".env 不支持执行 Shell 表达式。")
            }
            if chars[index] == "$" {
                var end = index + 1, name = ""
                if end < chars.count && chars[end] == "{" {
                    end += 1
                    while end < chars.count && chars[end] != "}" { name.append(chars[end]); end += 1 }
                    guard end < chars.count else { throw RuntimeFailure.message(".env 变量引用不完整。") }
                    end += 1
                } else {
                    while end < chars.count && (chars[end].isLetter || chars[end].isNumber || chars[end] == "_") { name.append(chars[end]); end += 1 }
                }
                if !name.isEmpty { output += environment[name] ?? ""; index = end; continue }
            }
            output.append(chars[index]); index += 1
        }
        return output
    }

    func saveWorkspaceRoot(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RuntimeFailure.message("请选择存在的绝对目录。")
        }
        let url = repositoryURL.appendingPathComponent(".env")
        let current = try String(contentsOf: url, encoding: .utf8)
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`")
        let assignment = "NOTION_LOCAL_OPS_WORKSPACE_ROOT=\"\(escaped)\""
        var found = false
        var lines = current.components(separatedBy: .newlines).map { line -> String in
            if line.range(of: "^\\s*(export\\s+)?NOTION_LOCAL_OPS_WORKSPACE_ROOT\\s*=", options: .regularExpression) != nil { found = true; return assignment }
            return line
        }
        if !found { lines.append(assignment) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// A child gets its own process group before exec, so shutdown never targets another app.
final class OwnedProcess: @unchecked Sendable {
    let pid: pid_t
    private(set) var reaped = false

    init(executable: URL, arguments: [String], configuration: RuntimeConfiguration, logName: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: configuration.logsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logURL = configuration.logsDirectory.appendingPathComponent(logName)
        let descriptor = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RuntimeFailure.message("无法打开服务日志。") }
        defer { close(descriptor) }
        fchmod(descriptor, 0o600)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, descriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptor, STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, configuration.repositoryURL.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var signalMask = sigset_t(), defaultSignals = sigset_t()
        sigemptyset(&signalMask)
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigmask(&attributes, &signalMask)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        // Swift worker threads block termination signals; children need normal process signals.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = configuration.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for value in argv + envp { free(value) } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&child, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw RuntimeFailure.message("无法启动 \(executable.lastPathComponent)：\(String(cString: strerror(result)))") }
        pid = child
    }

    func hasExited() -> Bool {
        if reaped { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) { reaped = true }
        return reaped
    }

    func stop(timeout: TimeInterval = 5) async {
        // Let the supervisor drain its server before cleaning up the remaining group.
        if !hasExited() { _ = kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasExited() { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = kill(-pid, SIGTERM)
        for _ in 0..<10 {
            _ = hasExited()
            if kill(-pid, 0) != 0 && errno == ESRCH { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = kill(-pid, SIGKILL)
        for _ in 0..<20 {
            if hasExited() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

@MainActor final class RuntimeManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    let configuration: RuntimeConfiguration
    private var supervisor: OwnedProcess?
    private var tunnel: OwnedProcess?
    private var monitor: Task<Void, Never>?
    private let primaryIPv4: () -> String?
    private var tunnelBindAddress: String?
    private var directTunnel = false
    private var tunnelRetryAt = Date.distantPast

    init(configuration: RuntimeConfiguration, primaryIPv4: @escaping () -> String? = RuntimeManager.currentPrimaryIPv4) {
        self.configuration = configuration
        self.primaryIPv4 = primaryIPv4
    }

    nonisolated static func currentPrimaryIPv4() -> String? {
        guard let network = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = network["PrimaryInterface"] as? String, interface.hasPrefix("en"),
              let ipv4 = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(interface)/IPv4" as CFString) as? [String: Any],
              let addresses = ipv4["Addresses"] as? [String] else { return nil }
        return addresses.first { value in
            var address = in_addr()
            return inet_pton(AF_INET, value, &address) == 1 && value != "0.0.0.0" && !value.hasPrefix("127.") && !value.hasPrefix("169.254.")
        }
    }

    func start() async {
        guard !isBusy, !isRunning else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let repository = configuration.repositoryURL
            let logs = configuration.logsDirectory
            let fresh = try await Task.detached { try RuntimeConfiguration.load(repositoryURL: repository, logsDirectory: logs) }.value
            let occupied = await Task.detached { Self.portReachable(fresh.localURL) }.value
            guard !occupied else { throw RuntimeFailure.message("端口 \(fresh.localURL.port ?? 8766) 已被其他服务占用；请先停止原服务再重试。") }
            supervisor = try await Task.detached {
                try OwnedProcess(executable: fresh.pythonURL, arguments: ["-m", "notion_local_ops_mcp.supervisor", "--log-file", fresh.logsDirectory.appendingPathComponent("server.log").path, "--pid-file", fresh.stateDirectory.appendingPathComponent("desktop-supervisor.pid").path, "--shutdown-timeout", "35"], configuration: fresh, logName: "supervisor.log")
            }.value
            let deadline = Date().addingTimeInterval(18)
            var ready = false
            while Date() < deadline {
                guard let supervisor, !supervisor.hasExited() else { throw RuntimeFailure.message("MCP 启动失败，请查看服务日志。") }
                if await Task.detached(operation: { Self.portReachable(fresh.localURL) }).value { ready = true; break }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            guard ready else { throw RuntimeFailure.message("等待本地 MCP 就绪超时，请查看日志。") }
            tunnel = try await launchTunnel(fresh)
            try await Task.sleep(nanoseconds: 600_000_000)
            guard let tunnel, !tunnel.hasExited() else { throw RuntimeFailure.message("Cloudflare 隧道启动失败，请查看隧道日志。") }
            guard supervisor?.hasExited() == false else { throw RuntimeFailure.message("MCP 启动后退出，请查看服务日志。") }
            isRunning = true
            beginMonitoring()
        } catch {
            errorMessage = error.localizedDescription
            await cleanup()
        }
    }

    private func launchTunnel(_ config: RuntimeConfiguration) async throws -> OwnedProcess {
        let direct = config.environment["NOTION_LOCAL_OPS_TUNNEL_DIRECT"] == "1"
        let address = direct ? primaryIPv4() : nil
        var args = ["tunnel", "--config", config.environment["NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG"]!]
        if direct {
            args += ["--edge-ip-version", "4"]
            // Bind only cloudflared; leave the user's system proxy and other apps untouched.
            if let address { args += ["--edge-bind-address", address] }
        }
        args.append("run")
        if let name = config.environment["NOTION_LOCAL_OPS_TUNNEL_NAME"], !name.isEmpty { args.append(name) }
        let arguments = args
        let process = try await Task.detached {
            try OwnedProcess(executable: config.cloudflaredURL, arguments: arguments, configuration: config, logName: "tunnel.log")
        }.value
        directTunnel = direct
        tunnelBindAddress = address
        return process
    }

    private func cleanup() async {
        monitor?.cancel(); monitor = nil
        let oldTunnel = tunnel, oldSupervisor = supervisor
        tunnel = nil; supervisor = nil; isRunning = false
        await Task.detached {
            await oldTunnel?.stop()
            await oldSupervisor?.stop(timeout: 38)
        }.value
    }

    func stop() async {
        while isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
        isBusy = true
        await cleanup()
        errorMessage = nil
        isBusy = false
    }

    func restart() async { guard !isBusy else { return }; await stop(); await start() }

    func restartTunnel() async {
        guard !isBusy, isRunning else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        monitor?.cancel(); monitor = nil
        await tunnel?.stop(); tunnel = nil
        do {
            let fresh = try RuntimeConfiguration.load(repositoryURL: configuration.repositoryURL, logsDirectory: configuration.logsDirectory)
            tunnel = try await launchTunnel(fresh)
            try await Task.sleep(nanoseconds: 600_000_000)
            guard tunnel?.hasExited() == false else { throw RuntimeFailure.message("隧道重启失败，请查看日志。") }
            tunnelRetryAt = .distantPast
        } catch {
            let failedTunnel = tunnel
            tunnel = nil
            await failedTunnel?.stop()
            errorMessage = "\(error.localizedDescription) 本地 MCP 继续运行，隧道稍后自动重试。"
            tunnelRetryAt = Date().addingTimeInterval(10)
        }
        // Restore the same supervised lifecycle after reconnecting the tunnel.
        if isRunning { beginMonitoring() }
    }

    private func beginMonitoring() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.supervisor?.hasExited() != false {
                    await self.stop()
                    self.errorMessage = "本地 MCP 进程意外退出，请查看日志后重启。"
                    return
                }
                if let failedTunnel = self.tunnel, failedTunnel.hasExited() {
                    self.tunnel = nil
                    self.errorMessage = "Cloudflare 隧道意外退出；本地 MCP 继续运行，稍后自动重试。"
                    self.tunnelRetryAt = Date().addingTimeInterval(10)
                    await failedTunnel.stop()
                    guard !Task.isCancelled, self.isRunning else { return }
                }
                let address = self.directTunnel ? self.primaryIPv4() : nil
                let networkChanged = self.directTunnel && address != nil && address != self.tunnelBindAddress
                if !self.isBusy, Date() >= self.tunnelRetryAt, (!self.directTunnel || address != nil), self.tunnel == nil || networkChanged {
                    // Do not cancel this task inside restartTunnel before its awaited relaunch.
                    self.monitor = nil
                    await self.restartTunnel()
                    return
                }
            }
        }
    }

    nonisolated static func portReachable(_ url: URL) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(url.port ?? 8766).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
