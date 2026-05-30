import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    /// Copy text to the pasteboard and paste it into the previously focused app.
    var onPaste: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button("Clear", role: .destructive) { history.clear() }
                    .disabled(history.entries.isEmpty)
            }
            .padding(12)
            Divider()

            if history.entries.isEmpty {
                Spacer()
                Text("No transcripts yet.\nDictate with your shortcut to fill this list.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(history.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.text).lineLimit(4)
                        HStack {
                            Text(entry.date, style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") { copy(entry.text) }
                            Button("Paste") { onPaste(entry.text) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 400, height: 380)
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
