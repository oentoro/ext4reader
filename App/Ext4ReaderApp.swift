import SwiftUI

@main struct Ext4ReaderApp: App {
    @State private var model = BrowserModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 800, minHeight: 500)
                .task { model.startDiskWatching() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    // Tutup volume sebelum keluar; tunggu singkat agar umount selesai.
                    let done = DispatchSemaphore(value: 0)
                    let vols = model.sources.compactMap(\.volume)
                    Task.detached { for v in vols { await BrowserModel.close(v) }; done.signal() }
                    _ = done.wait(timeout: .now() + 2)
                }
        }
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
