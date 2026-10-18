import Foundation

@main
struct ConsoleTypesCheck {
    static func main() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let inspectJSON = #"{"success":false,"local_ok":true,"public_ok":false,"auth_ok":true,"tools":[{"name":"read_text","description":"Read text"},{"name":"unknown_future_tool"}],"codex_available":true,"claude_available":false,"workspace_root":"/tmp/example","public_url":"https://example.test/mcp","error":"公网不可达"}"#
        let inspect = try decoder.decode(ConsoleInspection.self, from: Data(inspectJSON.utf8))
        assert(inspect.localOk == true && inspect.publicOk == false && inspect.authOk == true)
        assert(inspect.codexAvailable == true && inspect.claudeAvailable == false)
        assert(inspect.workspaceRoot == "/tmp/example" && inspect.publicUrl == "https://example.test/mcp")
        assert(inspect.tools?.first?.chineseTitle == "读取文本")
        assert(inspect.tools?.last?.chineseTitle == "unknown_future_tool")

        let snapshotJSON = #"{"success":true,"active_task_count":1,"active_call_count":2,"last_activity_at":"2026-10-18T09:30:00.000+00:00","events":[{"id":"event-1","tool":"read_text","title":"读取文本","started_at":"2026-10-18T09:30:00+00:00","duration_ms":12,"ok":true}],"tasks":[{"task_id":"abcdef123456","task":"example","executor":"shell","cwd":"/tmp","status":"queued","created_at":"2026-10-18T09:30:00+00:00","updated_at":"2026-10-18T09:30:00+00:00","stdout_tail":"out","stderr_tail":""}]}"#
        let snapshot = try decoder.decode(ConsoleSnapshot.self, from: Data(snapshotJSON.utf8))
        assert(snapshot.activeTaskCount == 1 && snapshot.activeCallCount == 2)
        assert(snapshot.events?.first?.durationMs == 12)
        assert(snapshot.tasks?.first?.id == "abcdef123456")
        assert(snapshot.tasks?.first?.isActive == true && snapshot.tasks?.first?.statusTitle == "排队中")
        assert(snapshot.tasks?.first?.stdoutTail == "out")
        assert(consoleDate(snapshot.lastActivityAt) != snapshot.lastActivityAt)
        assert(consoleDate(nil) == "暂无记录")
        let error = try decoder.decode(ConsoleActionResult.self, from: Data(#"{"success":false,"error":"任务未找到"}"#.utf8))
        assert(!error.success && error.error == "任务未找到")
        print("Console protocol checks passed")
    }
}
