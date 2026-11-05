import SwiftUI
import Ext4Kit

struct TreeView: View {
    let model: BrowserModel

    var body: some View {
        List { TreeChildren(model: model, path: "/") }
    }
}

/// Memuat anak `path` saat pertama tampil (lazy).
private struct TreeChildren: View {
    let model: BrowserModel
    let path: String
    @State private var items: [Entry]?

    var body: some View {
        Group {
            if let items {
                ForEach(items, id: \.path) { e in
                    if e.kind == .directory && e.hasValidName {
                        DirRow(model: model, entry: e)
                    } else {
                        RowContent(model: model, entry: e)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { items = await model.children(of: path) }
    }
}

private struct DirRow: View {
    let model: BrowserModel
    let entry: Entry
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            if open { TreeChildren(model: model, path: entry.path) }
        } label: {
            RowContent(model: model, entry: entry)
        }
    }
}

private struct RowContent: View {
    let model: BrowserModel
    let entry: Entry

    private func symbol(_ s: Selection.State) -> String {
        switch s {
        case .on: "checkmark.square"
        case .mixed: "minus.square"
        case .off: "square"
        }
    }

    var body: some View {
        let state = model.checkState(entry.path)
        HStack {
            Button { model.toggle(entry.path) } label: {
                Image(systemName: symbol(state))
            }
            .buttonStyle(.plain).disabled(!entry.hasValidName)
            Image(systemName: entry.kind == .directory ? "folder" : "doc")
            Text(entry.name)
            Spacer()
            if entry.kind != .directory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    .foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            }
            Text(entry.mtime.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
        }
    }
}
