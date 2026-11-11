import Photos
import SweepCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.auth {
            case .authorized:
                MainView()
            case .notDetermined:
                AccessView(
                    title: "PhotoSweep needs your Photos library",
                    detail: "It shows your photos and videos one at a time so you can decide what to keep. Nothing is deleted until you review your list and confirm.",
                    buttonTitle: "Allow Access",
                    action: model.requestAccess)
            default:
                AccessView(
                    title: "Photos access is turned off",
                    detail: "Turn on full access for PhotoSweep in System Settings → Privacy & Security → Photos, then reopen the app.",
                    buttonTitle: "Open System Settings"
                ) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .preferredColorScheme(.dark)
    }
}

private struct AccessView: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(title).font(.title.weight(.semibold))
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.13))
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    // Declared by hand: this SDK turns `@State` into a macro whose plugin only ships with full Xcode.
    private var _confirmReset = State<Bool>(initialValue: false)
    private var confirmReset: Bool {
        get { _confirmReset.wrappedValue }
        nonmutating set { _confirmReset.wrappedValue = newValue }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            DeckView()
        }
        .sheet(isPresented: $model.showReview) {
            ReviewSheet().environmentObject(model)
        }
        .alert(item: $model.deletionSummary) { summary in
            Alert(
                title: Text("Moved \(Format.count(summary.count)) \(summary.count == 1 ? "item" : "items") to Recently Deleted"),
                message: Text("That is \(Format.bytes(summary.bytes)). iCloud space is only freed once you empty Recently Deleted: open Photos, choose Recently Deleted in the sidebar, and click Delete All."),
                primaryButton: .default(Text("Open Photos")) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                        NSWorkspace.shared.open(url)
                    }
                },
                secondaryButton: .cancel(Text("Later")))
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Reset your progress?", isPresented: _confirmReset.projectedValue) {
            Button("Reset Progress", role: .destructive) { model.resetProgress() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything you kept or marked will come back into the queues. Nothing in your library changes.")
        }
    }

    private var sidebar: some View {
        List(selection: $model.selected) {
            section(.cleanup)
            section(.library)
            section(.albums)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            Picker("Counts", selection: $model.countMode) {
                Text("All items").tag(CountMode.all)
                Text("Left to swipe").tag(CountMode.left)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .help("Go through everything in each queue, or only what you have not swiped yet")
        }
        .toolbar {
            ToolbarItem {
                Button(action: model.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .help("Re-read albums and counts from Photos (⌘R)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deleted so far")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Format.count(model.store.deletedCount)) items · \(model.store.freedBytes > 0 ? Format.bytes(model.store.freedBytes) : "0 MB")")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                    Text("\(Format.count(model.store.kept.count)) kept")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Reset Progress…") { confirmReset = true }
                    .controlSize(.small)
                    .disabled(model.store.kept.isEmpty && model.store.marked.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func section(_ section: QueueSection) -> some View {
        let rows = model.queues.filter { $0.section == section }
        if !rows.isEmpty {
            Section(section.rawValue) {
                ForEach(rows) { queue in
                    Label(queue.title, systemImage: queue.symbol)
                        .badge(model.tally.count(queue.kind, mode: model.countMode))
                        .tag(queue.kind)
                }
                if section == .cleanup, let fraction = model.cleanupScanProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for more… \(Int(fraction * 100))%")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                }
            }
        }
    }
}
