import AppKit
import SwiftUI

@main
struct PhotoSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("PhotoSweep", id: "main") {
            RootView()
                .environmentObject(model)
                .onAppear {
                    delegate.model = model
                    if let path = SelfTest.requestedReportPath {
                        SelfTest.run(reportPath: path)
                    } else {
                        model.start()
                    }
                }
        }
        .defaultSize(width: 1240, height: 840)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo || model.showReview)
            }
            CommandGroup(replacing: .newItem) {
                Button("Refresh Library") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isAuthorized || model.isRefreshing)
                Divider()
                Button("Mark All Remaining for Deletion…") { model.requestMarkAll() }
                    .disabled(
                        !model.isAuthorized || model.deck.remaining == 0 || model.isLoading
                            || model.showReview || model.viewMode == .grid)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A self-test run only reads; it leaves saved progress exactly as it found it.
        if SelfTest.requestedReportPath == nil { model?.saveNow() }
    }
}
