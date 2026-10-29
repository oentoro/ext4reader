import SwiftUI

@main struct Ext4ReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: delegate.model)
                .frame(minWidth: 800, minHeight: 500)
                .task { delegate.model.startDiskWatching() }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BrowserModel()
    private var volumesClosed = false

    /// Keluar: batalkan backup dulu (runner menghapus partial di potongan berikut), tunggu ia
    /// selesai, lalu tutup volume. Semua menunggu dibatasi waktu agar app tetap bisa keluar.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.backup?.cancel()
        Task {
            await waitUntil(seconds: 10) { !(model.backup?.isRunning ?? false) }
            Task { await model.closeAll(); volumesClosed = true }
            await waitUntil(seconds: 2) { volumesClosed }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func waitUntil(seconds: Int, _ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !done() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

struct ContentView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if let s = model.selected, s.volume != nil {
                VStack(spacing: 0) {
                    TreeView(model: model).id(s.id)
                    Divider()
                    BottomBar(model: model)
                }
            } else {
                Text("Colok SSD ext4. Jika macOS bilang disk tidak dapat dibaca, pilih **Ignore**.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: Binding(get: { model.backup != nil }, set: { _ in })) {
            if let b = model.backup { BackupSheet(session: b) }
        }
        .alert("Ini terlihat seperti library Immich. Jadikan \(model.immichSuggestion?.path ?? "") akar backup?",
               isPresented: Binding(get: { model.immichSuggestion != nil }, set: { if !$0 { model.immichSuggestion = nil } })) {
            Button("Ya") { if let s = model.immichSuggestion, s.sourceID == model.selectedSourceID { model.setBackupRoot(s.path) }; model.immichSuggestion = nil }
            Button("Tidak", role: .cancel) { model.immichSuggestion = nil }
        }
        .alert("Ganti akar backup?",
               isPresented: Binding(get: { model.pendingRoot != nil }, set: { if !$0 { model.pendingRoot = nil } })) {
            Button("Ganti", role: .destructive) { if let p = model.pendingRoot { model.applyRoot(p) } }
            Button("Batal", role: .cancel) { model.pendingRoot = nil }
        } message: {
            Text("Setelah backup pernah dilakukan, mengganti akar membuat file dianggap baru di folder tujuan yang sama. Pilihan centang akan dikosongkan.")
        }
        .alert("Gagal", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
