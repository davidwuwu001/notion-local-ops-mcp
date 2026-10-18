import Foundation
import Darwin

@main struct RuntimeSelfTest {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notion-runtime-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try freePort()
        let env = """
        NOTION_LOCAL_OPS_AUTH_TOKEN='isolated-test-placeholder'
        NOTION_LOCAL_OPS_PORT=\(port)
        NOTION_LOCAL_OPS_STATE_DIR='\(root.path)/state'
        NOTION_LOCAL_OPS_WORKSPACE_ROOT='\(root.path)'
        NOTION_LOCAL_OPS_TUNNEL_DIRECT=1
        PATH="\(root.path):$PATH"
        """
        try env.write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "ingress:\n  - hostname: isolated.example.test\n".write(to: root.appendingPathComponent("cloudflared.local.yml"), atomically: true, encoding: .utf8)
        let fakePython = """
        #!/bin/sh
        exec /usr/bin/python3 -c 'import socket,os,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(os.environ["NOTION_LOCAL_OPS_PORT"]))); s.listen(); print(os.getpid(),flush=True); time.sleep(600)'
        """
        try executable(fakePython, at: root.appendingPathComponent(".venv/bin/python"))
        let tunnelArguments = root.appendingPathComponent("tunnel-arguments")
        let fakeTunnel = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(tunnelArguments.path)'\nexec /bin/sleep 600\n"
        try executable(fakeTunnel, at: root.appendingPathComponent("cloudflared"))
        var configuration = try RuntimeConfiguration.load(repositoryURL: root)
        // Keep even fake service logs isolated from the user's normal log directory.
        configuration = RuntimeConfiguration(repositoryURL: configuration.repositoryURL, pythonURL: configuration.pythonURL, cloudflaredURL: configuration.cloudflaredURL, stateDirectory: configuration.stateDirectory, logsDirectory: root.appendingPathComponent("logs"), environment: configuration.environment, localURL: configuration.localURL, publicURL: configuration.publicURL, workspaceRoot: configuration.workspaceRoot, authToken: configuration.authToken)
        assert(configuration.environment["PATH"]!.hasPrefix(root.path + ":"))
        assert(configuration.publicURL?.host == "isolated.example.test")
        let literal = try RuntimeConfiguration.envValue("'literal $PATH'", environment: [:])
        let expansion = try RuntimeConfiguration.envValue("\"${PATH}/bin\"", environment: ["PATH": "example"])
        assert(literal == "literal $PATH")
        assert(expansion == "example/bin")
        do { _ = try RuntimeConfiguration.envValue("$(touch forbidden)", environment: [:]); assertionFailure("Shell execution syntax accepted") } catch {}

        let renamed = root.appendingPathComponent("saved $literal")
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: false)
        try configuration.saveWorkspaceRoot(renamed.path)
        let saved = try RuntimeConfiguration.load(repositoryURL: root)
        assert(saved.workspaceRoot == renamed.path)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(".env").path)[.posixPermissions] as! NSNumber
        assert(permissions.intValue == 0o600)

        let maskProbe = try await Task.detached {
            var blockedSignals = sigset_t(), previousMask = sigset_t()
            sigemptyset(&blockedSignals)
            sigaddset(&blockedSignals, SIGTERM)
            pthread_sigmask(SIG_BLOCK, &blockedSignals, &previousMask)
            defer { pthread_sigmask(SIG_SETMASK, &previousMask, nil) }
            return try OwnedProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import signal; print(signal.pthread_sigmask(signal.SIG_BLOCK, []), flush=True)"], configuration: configuration, logName: "mask.log")
        }.value
        for _ in 0..<100 {
            if maskProbe.hasExited() { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let inheritedMask = try String(contentsOf: configuration.logsDirectory.appendingPathComponent("mask.log"), encoding: .utf8)
        assert(maskProbe.hasExited() && inheritedMask == "set()\n", "Child inherited the Swift worker's blocked signals: \(inheritedMask)")

        var primaryAddress: String? = "192.0.2.10"
        let runtime = RuntimeManager(configuration: configuration, primaryIPv4: { primaryAddress })
        await runtime.start()
        assert(runtime.isRunning, runtime.errorMessage ?? "Start failed")
        let supervisorLog = configuration.logsDirectory.appendingPathComponent("supervisor.log")
        let originalSupervisor = try String(contentsOf: supervisorLog, encoding: .utf8)
        let launchArguments = try String(contentsOf: tunnelArguments, encoding: .utf8)
        guard launchArguments.contains("--edge-bind-address\n192.0.2.10\n"), launchArguments.contains("--edge-ip-version\n4\n") else {
            await runtime.stop()
            throw RuntimeFailure.message("Direct tunnel did not bind the primary IPv4 interface")
        }
        primaryAddress = nil
        try await Task.sleep(nanoseconds: 1_200_000_000)
        assert(runtime.isRunning && RuntimeManager.portReachable(configuration.localURL), "Network loss stopped the local MCP")
        primaryAddress = "192.0.2.11"
        var rebound = false
        for _ in 0..<100 {
            if !runtime.isBusy, (try? String(contentsOf: tunnelArguments, encoding: .utf8))?.contains("--edge-bind-address\n192.0.2.11\n") == true {
                rebound = true; break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard rebound && runtime.isRunning && RuntimeManager.portReachable(configuration.localURL) else {
            await runtime.stop()
            throw RuntimeFailure.message("Network change did not reconnect only the tunnel")
        }
        try executable("#!/bin/sh\nexit 2\n", at: root.appendingPathComponent("cloudflared"))
        primaryAddress = "192.0.2.12"
        for _ in 0..<100 {
            if !runtime.isBusy && runtime.errorMessage != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard runtime.isRunning && RuntimeManager.portReachable(configuration.localURL) && runtime.errorMessage != nil else {
            await runtime.stop()
            throw RuntimeFailure.message("Failed network reconnect stopped the local MCP")
        }
        try executable(fakeTunnel, at: root.appendingPathComponent("cloudflared"))
        var recovered = false
        for _ in 0..<160 {
            if !runtime.isBusy, runtime.errorMessage == nil,
               (try? String(contentsOf: tunnelArguments, encoding: .utf8))?.contains("--edge-bind-address\n192.0.2.12\n") == true {
                recovered = true; break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard recovered && runtime.isRunning && RuntimeManager.portReachable(configuration.localURL) else {
            await runtime.stop()
            throw RuntimeFailure.message("Tunnel did not retry after a transient launch failure")
        }
        let recoveredSupervisor = try String(contentsOf: supervisorLog, encoding: .utf8)
        assert(originalSupervisor == recoveredSupervisor, "Tunnel recovery replaced the local MCP process")
        primaryAddress = nil
        await runtime.restartTunnel()
        assert(runtime.isRunning, "Tunnel restart stopped the server")
        let offlineArguments = try String(contentsOf: tunnelArguments, encoding: .utf8)
        assert(!offlineArguments.contains("--edge-bind-address"), "Network loss reused a stale source IP")
        let envURL = root.appendingPathComponent(".env")
        let currentEnv = try String(contentsOf: envURL, encoding: .utf8)
        try (currentEnv + "\nNOTION_LOCAL_OPS_TUNNEL_DIRECT=0\n").write(to: envURL, atomically: true, encoding: .utf8)
        primaryAddress = "192.0.2.12"
        await runtime.restartTunnel()
        let defaultArguments = try String(contentsOf: tunnelArguments, encoding: .utf8)
        assert(!defaultArguments.contains("--edge-bind-address") && !defaultArguments.contains("--edge-ip-version"), "Default routing was overridden without opt-in")
        let conflict = RuntimeManager(configuration: configuration)
        await conflict.start()
        assert(!conflict.isRunning && conflict.errorMessage?.contains("占用") == true)
        assert(RuntimeManager.portReachable(configuration.localURL), "Conflict check killed another owner")
        await runtime.stop()
        assert(!runtime.isRunning && !RuntimeManager.portReachable(configuration.localURL))

        try executable("#!/bin/sh\nexit 2\n", at: root.appendingPathComponent("cloudflared"))
        await runtime.start()
        if runtime.isRunning || runtime.errorMessage == nil {
            let detail = "partial failure: running=\(runtime.isRunning), error=\(runtime.errorMessage ?? "nil")"
            await runtime.stop()
            throw RuntimeFailure.message(detail)
        }
        assert(!RuntimeManager.portReachable(configuration.localURL), "Partial startup leaked server")

        try executable("#!/bin/sh\nsleep 1.5\nexit 2\n", at: root.appendingPathComponent("cloudflared"))
        await runtime.start()
        assert(runtime.isRunning, runtime.errorMessage ?? "Unexpected exit fixture did not start")
        for _ in 0..<100 {
            if runtime.errorMessage?.contains("意外退出") == true && !runtime.isBusy { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assert(runtime.isRunning && RuntimeManager.portReachable(configuration.localURL) && runtime.errorMessage?.contains("意外退出") == true, "Tunnel exit stopped local MCP or lost its error")
        await runtime.stop()

        try executable(fakeTunnel, at: root.appendingPathComponent("cloudflared"))
        try executable(fakePython.replacingOccurrences(of: "time.sleep(600)", with: "time.sleep(1.5)"), at: root.appendingPathComponent(".venv/bin/python"))
        await runtime.start()
        assert(runtime.isRunning, "Local MCP exit fixture did not start")
        for _ in 0..<100 {
            if !runtime.isRunning && !runtime.isBusy { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assert(!runtime.isRunning && !RuntimeManager.portReachable(configuration.localURL) && runtime.errorMessage?.contains("本地 MCP") == true, "Local MCP exit was mistaken for a tunnel-only failure")

        let short = try OwnedProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], configuration: configuration, logName: "owned.log")
        var reapedStatus: Int32 = 0
        _ = waitpid(short.pid, &reapedStatus, 0)
        assert(short.hasExited(), "An already reaped child was treated as running")

        let childFile = root.appendingPathComponent("grandchild.pid")
        let owned = try OwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 600 & echo $! > '\(childFile.path)'; wait"], configuration: configuration, logName: "owned.log")
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: childFile.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let child = Int32(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        await owned.stop(timeout: 1)
        assert(owned.hasExited())
        for _ in 0..<20 {
            if kill(child, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        assert(kill(child, 0) != 0, "Owned grandchild survived stop")
        print("PASS: env parsing/persistence, clean child signal mask, direct IPv4 binding/network-change reconnect/offline/default routing, start/stop, tunnel restart, occupied port, partial failure, unexpected exit, already reaped child, process-group cleanup")
    }

    static func executable(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw RuntimeFailure.message("No isolated test port") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { pointer in
            _ = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
