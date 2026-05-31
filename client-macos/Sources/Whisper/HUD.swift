import AppKit
import Combine
import SwiftUI

/// Non-activating panel that can still take clicks: it becomes key *within our (inactive) app*
/// so buttons work, but never activates the app — the focused app stays frontmost so paste lands.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Tracking-area host so hover works even though the panel is never the system key window
/// (SwiftUI `.onHover` won't fire there). Resizes are handled by the controller.
final class HoverHostView: NSView {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The persistent floating pill at bottom-center. Compact when idle; expands on hover (Start)
/// and while recording (waveform + Stop) / transcribing.
final class HUDController {
    private let panel: HUDPanel
    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState, onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        appState = state
        let hosting = NSHostingView(rootView: HUDView(state: state, onStart: onStart, onStop: onStop))
        hosting.autoresizingMask = [.width, .height]
        let container = HoverHostView()
        container.onHover = { [weak state] inside in state?.hudHovering = inside }
        hosting.frame = container.bounds
        container.addSubview(hosting)

        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 130, height: 30),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: true)
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        Publishers.CombineLatest(state.$phase, state.$hudHovering)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, hovering in self?.layout(phase: phase, hovering: hovering) }
            .store(in: &cancellables)
    }

    func show() { layout(phase: appState.phase, hovering: appState.hudHovering); panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    private func layout(phase: DictationPhase, hovering: Bool) {
        let size = Self.size(phase: phase, hovering: hovering)
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 18)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private static func size(phase: DictationPhase, hovering: Bool) -> NSSize {
        switch phase {
        case .idle:         return hovering ? NSSize(width: 222, height: 42) : NSSize(width: 72, height: 26)
        case .recording:    return NSSize(width: 330, height: 54)
        case .transcribing: return NSSize(width: 240, height: 46)
        case .inserted, .copied, .error: return NSSize(width: 300, height: 46)
        }
    }
}

struct HUDView: View {
    @ObservedObject var state: AppState
    var onStart: () -> Void
    var onStop: () -> Void
    @State private var bars: [CGFloat] = Array(repeating: 0.06, count: 22)

    private var compact: Bool { state.phase == .idle && !state.hudExpanded }

    var body: some View {
        content
            .padding(.horizontal, compact ? 9 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .onChange(of: state.level) { v in bars.removeFirst(); bars.append(max(0.06, v)) }
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .idle:
            if state.hudExpanded {
                HStack(spacing: 10) {
                    statusDot
                    Button(action: onStart) { Label("Start", systemImage: "mic.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Spacer(minLength: 0)
                    Text(state.serverStatus.label).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                // Compact idle: minimal + low-intensity so it doesn't distract during focus work.
                HStack(spacing: 5) {
                    Circle().fill(statusColor.opacity(0.45)).frame(width: 5, height: 5)
                    Image(systemName: "mic").font(.system(size: 11)).foregroundStyle(.secondary)
                    if state.pendingCount > 0 {
                        Text("\(state.pendingCount)").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange.opacity(0.85))
                    }
                }
            }
        case .recording:
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 9, height: 9)
                waveform
                Text(timeString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Button(action: onStop) { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.red)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("transcribing…").font(.callout)
                Spacer(minLength: 0)
                Text(timeString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        case .inserted:
            label("checkmark.circle.fill", .green, "inserted")
        case .copied:
            label("doc.on.clipboard", .yellow, "Copied — ⌘V to paste")
        case .error(let message):
            label("exclamationmark.triangle.fill", .orange, message)
        }
    }

    private func label(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var statusDot: some View {
        Circle().fill(statusColor).frame(width: 8, height: 8)
    }
    private var statusColor: Color {
        switch state.serverStatus {
        case .up: return .green
        case .backendDown: return .orange
        case .unreachable: return .red
        case .unknown: return .gray
        }
    }
    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule().fill(.primary.opacity(0.85)).frame(width: 2, height: 4 + bars[i] * 22)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 26)
    }
    private var timeString: String {
        let s = Int(state.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
