import Foundation

struct ConsoleTool: Decodable, Identifiable {
    let name: String
    let description: String?
    var id: String { name }
    var category: String {
        if name.hasPrefix("git_") { return "Git" }
        if ["delegate_task", "get_task", "wait_task", "cancel_task", "purge_tasks"].contains(name) { return "任务" }
        if name.hasPrefix("run_command") { return "命令" }
        if ["list_files", "read_text", "write_file", "apply_patch", "search"].contains(name) { return "文件与搜索" }
        return "连接与配置"
    }
    var chineseTitle: String {
        ["list_files": "浏览文件", "read_text": "读取文本", "write_file": "写入文件",
         "apply_patch": "修改文件", "search": "搜索文件与内容", "git_status": "查看 Git 状态",
         "git_diff": "查看文件差异", "git_commit": "提交 Git 变更", "git_log": "查看提交历史",
         "git_show": "查看提交内容", "git_blame": "查看代码归属", "run_command": "执行命令",
         "run_command_stream": "后台执行命令", "delegate_task": "委派 AI 任务", "get_task": "查看任务",
         "wait_task": "等待任务完成", "cancel_task": "停止任务", "purge_tasks": "清理任务记录",
         "server_info": "查看服务信息", "get_default_cwd": "查看默认目录", "set_default_cwd": "设置默认目录",
         "list_skills": "查看技能", "bind_relay_run": "绑定活动看板", "clear_relay_run": "解除看板绑定"][name] ?? name
    }
}

struct ConsoleInspection: Decodable {
    let success: Bool
    let localOk: Bool?
    let publicOk: Bool?
    let authOk: Bool?
    let tools: [ConsoleTool]?
    let codexAvailable: Bool?
    let claudeAvailable: Bool?
    let workspaceRoot: String?
    let publicUrl: String?
    let error: String?
}

struct ConsoleEvent: Decodable, Identifiable {
    let id: String
    let tool: String
    let title: String?
    let startedAt: String?
    let durationMs: Double?
    let ok: Bool?
    let error: String?
}

struct ConsoleTask: Decodable, Identifiable {
    let taskId: String
    let task: String?
    let executor: String?
    let cwd: String?
    let status: String
    let createdAt: String?
    let updatedAt: String?
    let stdoutTail: String?
    let stderrTail: String?
    var id: String { taskId }
    var isActive: Bool { ["queued", "running"].contains(status) }
    var statusTitle: String {
        ["queued": "排队中", "running": "运行中", "succeeded": "已完成", "failed": "失败", "cancelled": "已停止"][status] ?? status
    }
}

struct ConsoleSnapshot: Decodable {
    let success: Bool
    let events: [ConsoleEvent]?
    let tasks: [ConsoleTask]?
    let lastActivityAt: String?
    let activeTaskCount: Int?
    let activeCallCount: Int?
    let error: String?
}

struct ConsoleActionResult: Decodable {
    let success: Bool
    let error: String?
}

enum ConsolePage: String, CaseIterable, Identifiable {
    case overview = "总览"
    case tools = "工具与任务"
    case settings = "设置与诊断"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "slider.horizontal.3"
        }
    }
}

func consoleDate(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "暂无记录" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date?.formatted(date: .abbreviated, time: .standard) ?? value
}
