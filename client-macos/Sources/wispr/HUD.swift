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
    override func mouseDown(with event: NSEvent) {
        window?.performWindowDrag(with: event)
    }
}

/// Background helper view that forwards mouse-down drag events to the AppKit window server
struct WindowDragRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performWindowDrag(with: event)
        }
    }
}

/// The persistent floating pill at bottom-center. Compact when idle; expands on hover (Start)
/// and while preparing / recording (waveform + Stop) / finishing / transcribing / recovering.
final class HUDController {
    private let panel: HUDPanel
    private let appState: AppState
    private let container = HoverHostView()
    private var cancellables = Set<AnyCancellable>()
    private var didLayout = false
    private var collapseWork: DispatchWorkItem?
    private static let posXKey = "wispr.hud.centerX"
    private static let posYKey = "wispr.hud.centerY"
    private var userCenter: NSPoint?
    private var isProgrammaticLayout = false

    init(state: AppState, onStart: @escaping () -> Void, onStop: @escaping () -> Void, onCancel: @escaping () -> Void) {
        appState = state
        let hosting = NSHostingView(rootView: HUDView(state: state, onStart: onStart, onStop: onStop, onCancel: onCancel))
        hosting.autoresizingMask = [.width, .height]
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
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        userCenter = Self.loadSavedPosition()

        Publishers.CombineLatest(state.$phase, state.$hudHovering)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, hovering in self?.layout(phase: phase, hovering: hovering) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isProgrammaticLayout else { return }
                let frame = self.panel.frame
                let center = NSPoint(x: frame.midX, y: frame.midY)
                self.userCenter = center
                Self.savePosition(center)
            }
            .store(in: &cancellables)

        // Route hover through a small debounce so the resize doesn't flicker at the edge.
        container.onHover = { [weak self] inside in self?.setHover(inside) }
    }

    func show() { layout(phase: appState.phase, hovering: appState.hudHovering); panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    private func setHover(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            appState.hudHovering = true
        } else {
            let work = DispatchWorkItem { [weak self] in self?.appState.hudHovering = false }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }

    private static func loadSavedPosition() -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: posXKey) != nil, d.object(forKey: posYKey) != nil else { return nil }
        return NSPoint(x: d.double(forKey: posXKey), y: d.double(forKey: posYKey))
    }

    private static func savePosition(_ center: NSPoint) {
        let d = UserDefaults.standard
        d.set(Double(center.x), forKey: posXKey)
        d.set(Double(center.y), forKey: posYKey)
    }

    private func layout(phase: DictationPhase, hovering: Bool) {
        let size = Self.size(phase: phase, hovering: hovering)
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame

        let targetCenter: NSPoint
        if let center = userCenter {
            let minX = vf.minX + size.width / 2
            let maxX = vf.maxX - size.width / 2
            let minY = vf.minY + size.height / 2
            let maxY = vf.maxY - size.height / 2
            let clampedX = minX < maxX ? max(minX, min(maxX, center.x)) : vf.midX
            let clampedY = minY < maxY ? max(minY, min(maxY, center.y)) : vf.minY + 18 + size.height / 2
            targetCenter = NSPoint(x: clampedX, y: clampedY)
        } else {
            targetCenter = NSPoint(x: vf.midX, y: vf.minY + 18 + size.height / 2)
        }

        let origin = NSPoint(x: targetCenter.x - size.width / 2, y: targetCenter.y - size.height / 2)
        let rect = NSRect(origin: origin, size: size)

        isProgrammaticLayout = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.isProgrammaticLayout = false
            }
        }

        guard didLayout else { panel.setFrame(rect, display: true); didLayout = true; return }
        // Animate the magnify so it's smooth (not a jump).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(rect, display: true)
        }
    }

    private static func size(phase: DictationPhase, hovering: Bool) -> NSSize {
        switch phase {
        case .idle:         return hovering ? NSSize(width: 222, height: 42) : NSSize(width: 72, height: 26)
        case .preparing:    return NSSize(width: 260, height: 46)
        case .recording:    return NSSize(width: 372, height: 54)
        case .finishing:    return NSSize(width: 282, height: 46)
        case .transcribing: return NSSize(width: 240, height: 46)
        case .recovering:   return NSSize(width: 292, height: 46)
        case .inserted, .copied, .available, .error: return NSSize(width: 300, height: 46)
        }
    }
}

struct HUDView: View {
    @ObservedObject var state: AppState
    var onStart: () -> Void
    var onStop: () -> Void
    var onCancel: () -> Void
    @State private var bars: [CGFloat] = Array(repeating: 0.06, count: 32)

    private var compact: Bool { state.phase == .idle && !state.hudExpanded }

    var body: some View {
        content
            .padding(.horizontal, compact ? 9 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WindowDragRepresentable())
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
                .contentShape(Rectangle())
                .overlay(WindowDragRepresentable())
            }
        case .preparing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("checking server…").font(.callout)
                Spacer(minLength: 0)
                Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Cancel (Esc)")
            }
        case .recording:
            HStack(spacing: 8) {
                RecordingDot()
                waveform
                Text(timeString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Cancel (Esc)")
                Button(action: onStop) { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.red)
            }
        case .finishing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("finishing recording…").font(.callout)
                Spacer(minLength: 0)
                Text(timeString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("transcribing…").font(.callout)
                Spacer(minLength: 0)
                Text(timeString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        case .recovering:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("recovering transcript…").font(.callout)
                Spacer(minLength: 0)
                Text(timeString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        case .inserted:
            label("checkmark.circle.fill", .green, "inserted")
        case .copied:
            label("doc.on.clipboard", .yellow, "Copied — ⌘V to paste")
        case .available:
            label("doc.text", .yellow, "Transcript ready")
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
        case .loading: return .yellow
        case .loggedOut, .backendDown, .serverOffline, .unauthorized: return .orange
        case .unreachable: return .red
        case .unknown: return .gray
        }
    }
    private var waveform: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2.5
            let n = bars.count
            let barW = max(1.5, (geo.size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(bars.indices, id: \.self) { i in
                    Capsule().fill(.primary.opacity(0.85))
                        .frame(width: barW, height: 4 + bars[i] * 22)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .padding(.horizontal, 3) // stop a little before the dot (left) and the time counter (right)
    }
    private var timeString: String {
        let s = Int(state.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The recording indicator: a red dot that gently pulses so it reads as "live recording"
/// (distinct from the idle status dot, which shows green=online / red=offline).
private struct RecordingDot: View {
    @State private var dim = false
    var body: some View {
        Circle().fill(.red).frame(width: 9, height: 9)
            .opacity(dim ? 0.4 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
