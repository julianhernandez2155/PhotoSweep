import Photos
import SweepCore
import SwiftUI

/// The swipe area: the current card, the next one underneath, and the controls around them.
struct DeckView: View {
    @EnvironmentObject private var model: AppModel
    // Declared by hand: this SDK turns `@State` into a macro whose plugin only ships with full Xcode.
    private var _drag = State<CGSize>(initialValue: .zero)
    private var drag: CGSize {
        get { _drag.wrappedValue }
        nonmutating set { _drag.wrappedValue = newValue }
    }
    private var _flying = State<Bool>(initialValue: false)
    private var flying: Bool {
        get { _flying.wrappedValue }
        nonmutating set { _flying.wrappedValue = newValue }
    }

    private let commitDistance: CGFloat = 130

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack { stage }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .padding(.bottom, 12)
            infoLine
            controls
        }
        .background(Color(white: 0.13))
        .onReceive(model.actions, perform: handle)
        .confirmationDialog(markAllTitle, isPresented: $model.confirmMarkAll) {
            Button("Add \(Format.count(model.deck.remaining)) to Delete List", role: .destructive) {
                model.markAllRemaining()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only adds them to your delete list. Nothing is deleted until you review the list and confirm, and Undo takes them all back off.")
        }
    }

    private var markAllTitle: String {
        let count = model.deck.remaining
        let noun = count == 1 ? "item" : "items"
        return "Mark the \(Format.count(count)) remaining \(noun) in “\(model.selectedQueue?.title ?? "this queue")” for deletion?"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedQueue?.title ?? "PhotoSweep")
                    .font(.headline)
                Text(positionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if model.deck.total > 0 {
                ProgressView(value: Double(model.deck.cursor), total: Double(model.deck.total))
                    .frame(maxWidth: 220)
            }
            Spacer()
            Picker("Sort", selection: $model.sort) {
                ForEach(sortChoices) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Order of this queue")

            Menu {
                Button("Mark All Remaining for Deletion…") { model.confirmMarkAll = true }
                    .disabled(model.deck.remaining == 0 || model.isLoading)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("More actions for this queue")

            Button {
                model.showReview = true
            } label: {
                Label(reviewText, systemImage: "trash")
                    .monospacedDigit()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(model.store.marked.isEmpty)
            .help("Review what you marked, then delete it")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var sortChoices: [SortOrder] {
        let canHaveVideo = model.selected?.canContainVideo ?? true
        return SortOrder.allCases.filter { $0 != .longest || canHaveVideo }
    }

    private var positionText: String {
        let deck = model.deck
        guard deck.total > 0 else { return " " }
        if deck.isFinished { return "All \(Format.count(deck.total)) reviewed" }
        return "\(Format.count(deck.position)) of \(Format.count(deck.total))"
    }

    private var reviewText: String {
        let store = model.store
        guard !store.marked.isEmpty else { return "Nothing marked" }
        return "\(Format.count(store.marked.count)) marked · \(Format.bytes(store.totalMarkedBytes))"
    }

    // MARK: - Cards

    @ViewBuilder private var stage: some View {
        if model.isLoading {
            VStack(spacing: 12) {
                if let fraction = model.sizingProgress {
                    ProgressView(value: fraction).frame(width: 260)
                    Text("Measuring file sizes… \(Int(fraction * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.large)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            }
        } else if model.selected == nil {
            message("Pick a queue", "Choose what to sort through in the sidebar.", symbol: "sidebar.left")
        } else if model.deck.total == 0 {
            message("Nothing left here", "Everything in this queue already has a decision.", symbol: "checkmark.circle")
        } else if model.deck.isFinished {
            finished
        } else {
            if let next = model.nextAsset {
                AssetCard(asset: next, isActive: false)
                    .id("next-" + next.localIdentifier)
                    .scaleEffect(0.96)
                    .allowsHitTesting(false)
            }
            if let current = model.currentAsset {
                AssetCard(asset: current, isActive: true)
                    .id(current.localIdentifier)
                    .overlay { stamps }
                    .offset(drag)
                    .rotationEffect(.degrees(Double(drag.width) / 28))
                    .gesture(dragGesture)
            }
        }
    }

    private var stamps: some View {
        ZStack {
            stamp("DELETE", color: .red)
                .opacity(Double(min(max(-drag.width / commitDistance, 0), 1)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            stamp("KEEP", color: .green)
                .opacity(Double(min(max(drag.width / commitDistance, 0), 1)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(26)
        .allowsHitTesting(false)
    }

    private func stamp(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 3))
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("Queue finished").font(.title2.weight(.semibold))
            if model.store.marked.isEmpty {
                Text("Nothing is marked for deletion.").foregroundStyle(.secondary)
            } else {
                Text("\(Format.count(model.store.marked.count)) items are waiting in your delete list.")
                    .foregroundStyle(.secondary)
                Button("Review and Delete") { model.showReview = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
            }
        }
    }

    private func message(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
        }
    }

    // MARK: - Info and controls

    private var infoLine: some View {
        HStack(spacing: 18) {
            if let asset = model.currentAsset, !model.isLoading {
                Label(Format.date(asset.creationDate), systemImage: "calendar")
                Label(Format.bytes(model.size(for: asset)), systemImage: "internaldrive")
                Label("\(asset.pixelWidth) × \(asset.pixelHeight)", systemImage: "aspectratio")
                if asset.mediaType == .video {
                    Label(Format.duration(asset.duration), systemImage: "clock")
                }
            } else {
                Text(" ")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 22)
    }

    private var controls: some View {
        HStack(spacing: 34) {
            RoundButton(symbol: "xmark", label: "Delete", hint: "←", color: .red) {
                commit(.delete)
            }
            .disabled(model.currentAsset == nil || model.isLoading)

            RoundButton(symbol: "arrow.uturn.backward", label: "Undo", hint: "↑", color: .secondary, small: true) {
                model.undo()
            }
            .disabled(!model.deck.canUndo || model.isLoading)

            RoundButton(symbol: "checkmark", label: "Keep", hint: "→", color: .green) {
                commit(.keep)
            }
            .disabled(model.currentAsset == nil || model.isLoading)
        }
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    // MARK: - Swiping

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if !flying { drag = value.translation }
            }
            .onEnded { value in
                settle(value.translation.width)
            }
    }

    private func handle(_ action: DeckAction) {
        guard model.currentAsset != nil, !model.isLoading else { return }
        switch action {
        case .swipe(let decision):
            commit(decision)
        case .scroll(let delta):
            if !flying { drag.width += delta }
        case .scrollEnded:
            settle(drag.width)
        }
    }

    /// Finishes a drag or trackpad swipe: commit if it went far enough, otherwise snap back.
    private func settle(_ distance: CGFloat) {
        guard !flying else { return }
        if distance <= -commitDistance {
            commit(.delete)
        } else if distance >= commitDistance {
            commit(.keep)
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { drag = .zero }
        }
    }

    /// Flies the card off to one side, then records the decision.
    private func commit(_ decision: Decision) {
        guard !flying, model.currentAsset != nil, !model.isLoading else { return }
        flying = true
        withAnimation(.easeIn(duration: 0.16)) {
            drag = CGSize(width: decision == .keep ? 1500 : -1500, height: drag.height + 30)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            model.decide(decision)
            drag = .zero
            flying = false
        }
    }
}

private struct RoundButton: View {
    let symbol: String
    let label: String
    let hint: String
    let color: Color
    var small = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: small ? 17 : 24, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: small ? 46 : 64, height: small ? 46 : 64)
                    .background(Color(white: 0.2), in: Circle())
                    .overlay(Circle().stroke(color.opacity(0.55), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            Text("\(label)  \(hint)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(isEnabled ? 1 : 0.35)
    }
}
