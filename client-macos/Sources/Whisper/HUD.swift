import AppKit
import SwiftUI

/// The floating dictation pill: a borderless, non-activating panel near the bottom of the
/// screen. Non-activating + ignoresMouseEvents is essential — it must never steal key focus
/// from the app you're dictating into, or the ⌘V paste would land in the wrong place.
final class HUDController {
    private let panel: NSPanel

    init(state: AppState) {
        let host = NSHostingView(rootView: HUDView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 52)
        panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    func show() {
        positionBottomCenter()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 28))
    }
}

struct HUDView: View {
    @ObservedObject var state: AppState
    @State private var bars: [CGFloat] = Array(repeating: 0.06, count: 28)

    var body: some View {
        HStack(spacing: 12) {
            dot
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: 360, height: 52)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .opacity(state.phase == .idle ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: state.level)
        .onChange(of: state.level) { newValue in
            bars.removeFirst()
            bars.append(max(0.06, newValue))
        }
    }

    private var dot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 10, height: 10)
            .shadow(color: dotColor.opacity(0.7), radius: 4)
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .recording:
            waveform
            Text(timeString)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        case .transcribing:
            ProgressView().controlSize(.small)
            Text("transcribing…").font(.callout)
            Spacer(minLength: 0)
            Text(timeString)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        case .inserted:
            Text("inserted").font(.callout).foregroundStyle(.green)
        case .error(let message):
            Text(message).font(.callout).foregroundStyle(.red).lineLimit(1)
        case .idle:
            EmptyView()
        }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule()
                    .fill(.primary.opacity(0.85))
                    .frame(width: 2.5, height: 4 + bars[i] * 26)
            }
        }
        .frame(height: 30)
    }

    private var dotColor: Color {
        switch state.phase {
        case .recording: return .red
        case .transcribing: return .yellow
        case .inserted: return .green
        case .error: return .orange
        case .idle: return .gray
        }
    }

    private var timeString: String {
        let s = Int(state.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
