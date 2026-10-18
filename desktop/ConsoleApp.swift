import SwiftUI
import AppKit

@main struct LocalOpsConsoleApp: App {
    @NSApplicationDelegateAdaptor(ConsoleAppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor final class ConsoleAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var model: ConsoleModel?
    private var quitInProgress = false
    private var quitApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        do {
            let runtime = RuntimeManager(configuration: try RuntimeConfiguration.load())
            let model = ConsoleModel(runtime: runtime)
            self.model = model
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "本地 MCP 控制台"
            window.minSize = NSSize(width: 880, height: 600)
            window.contentView = NSHostingView(rootView: ConsoleView(model: model))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center(); window.makeKeyAndOrderFront(nil)
            self.window = window
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.start() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "控制台无法启动"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitApproved || model == nil { return .terminateNow }
        guard !quitInProgress, let model else { return .terminateCancel }
        quitInProgress = true
        Task {
            let approved = await model.requestQuit()
            quitInProgress = false
            quitApproved = approved
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }
}
