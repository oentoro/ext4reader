import SwiftUI
import AppKit

struct SidebarView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        List(selection: $model.selectedSourceID) {
            ForEach(model.sources) { s in
                Label(s.title, systemImage: "externaldrive")
                    .badge(Text(icon(s.status)))
                    .tag(s.id)
                    .help(isNeedsOpen(s.status) ? "Klik untuk membuka, perlu password admin" : "")
                    .onTapGesture { if isNeedsOpen(s.status) { Task { await model.openCandidate(s.id) } } }
                    .contextMenu { Button("Tutup") { Task { await model.removeSource(s.id) } } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Buka image…", action: pick).padding(8)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private func isNeedsOpen(_ s: BrowserModel.Status) -> Bool { if case .needsOpen = s { true } else { false } }

    private func icon(_ s: BrowserModel.Status) -> String {
        switch s {
        case .readOnly: "🔒"
        case .notClean: "⚠️"
        case .unsupported: "⛔"
        case .needsOpen: "🔑"
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { await model.openImage(url) }
    }
}
