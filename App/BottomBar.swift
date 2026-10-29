import SwiftUI

struct BottomBar: View {
    let model: BrowserModel

    var body: some View {
        HStack {
            if let t = model.totals {
                Text("Dipilih: \(t.files) file · \(ByteCountFormatter.string(fromByteCount: Int64(t.bytes), countStyle: .file))")
            } else {
                Text("Dipilih: menghitung…")
            }
            Spacer()
            Button("Backup ke…") { model.startBackup() }
                .disabled(model.totals?.files ?? 0 == 0)
        }
        .padding(8)
    }
}
