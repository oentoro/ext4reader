import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os
import Ext4Kit

/// Satu sesi backup: pratinjau -> progress -> laporan. Dimiliki BrowserModel selama sheet terbuka.
@MainActor @Observable final class BackupSession {
    enum Phase {
        case planning
        case preview(BackupPlan)
        case failed(String)
        case running
        case report(BackupReport)
    }
    var phase: Phase = .planning
    var progress: BackupProgress?
    var speed: Double?                 // byte/detik, rata-rata bergerak 5 detik
    var cancelling = false

    private unowned let model: BrowserModel
    private let volume: Volume
    private let root: String
    private let selection: Selection
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)   // dibaca dari actor LwExt4
    private var samples: [(t: ContinuousClock.Instant, bytes: UInt64)] = []
    private var planTask: Task<Void, Never>?

    init(model: BrowserModel, volume: Volume, root: String, selection: Selection) {
        self.model = model; self.volume = volume; self.root = root; self.selection = selection
        replan()
    }

    var destination: URL? { model.settings.destination.map { URL(fileURLWithPath: $0) } }

    var isRunning: Bool { if case .running = phase { true } else { false } }

    func replan() {
        planTask?.cancel()
        guard let dest = destination else { phase = .failed("Folder tujuan tidak ditemukan. Colok disk tujuan atau pilih folder lain."); return }
        phase = .planning
        let (v, r, s) = (volume, root, selection)
        planTask = Task {
            let res = await Self.plan(v, r, s, dest)
            if Task.isCancelled { return }
            switch res {
            case .success(let p): phase = .preview(p)
            case .failure(.notClean): phase = .failed("Disk ini tidak dilepas dengan bersih. Mount lalu umount disk ini sekali di Linux.")
            case .failure(.destinationMissing): phase = .failed("Folder tujuan tidak ditemukan. Colok disk tujuan atau pilih folder lain.")
            case .failure(let e): phase = .failed("Gagal membuat rencana backup: \(e)")
            }
        }
    }

    func changeDestination() {
        guard let url = BrowserModel.pickFolder() else { return }
        model.settings.destination = url.path
        replan()
    }

    func start(_ plan: BackupPlan) {
        guard let dest = destination else { return }
        phase = .running; progress = nil; speed = nil; cancelling = false; samples = []
        cancelFlag.withLock { $0 = false }
        let (v, flag) = (volume, cancelFlag)
        Task {
            let report = await Self.run(plan, v, dest, flag) { [weak self] p in
                Task { @MainActor in self?.received(p) }
            }
            phase = .report(report)
        }
    }

    func cancel() { cancelling = true; cancelFlag.withLock { $0 = true } }

    private func received(_ p: BackupProgress) {
        guard isRunning else { return }   // update terlambat setelah laporan
        progress = p
        let now = ContinuousClock.now
        samples.append((now, p.bytesDone))
        samples.removeAll { now - $0.t > .seconds(5) }
        if let f = samples.first, let l = samples.last, l.t > f.t {
            let dt = Double((l.t - f.t).components.seconds) + Double((l.t - f.t).components.attoseconds) / 1e18
            speed = Double(l.bytes - f.bytes) / dt
        }
    }

    func close() { planTask?.cancel(); model.backup = nil }

    @LwExt4 private static func plan(_ v: Volume, _ root: String, _ sel: Selection, _ dest: URL)
        -> Result<BackupPlan, Ext4Error> {
        do { return .success(try makePlan(v, root: root, selection: sel, destination: dest)) }
        catch { return .failure(error) }
    }

    @LwExt4 private static func run(_ plan: BackupPlan, _ v: Volume, _ dest: URL,
                                    _ flag: OSAllocatedUnfairLock<Bool>,
                                    _ emit: @Sendable (BackupProgress) -> Void) -> BackupReport {
        var last = ContinuousClock.now - .seconds(1)
        return runBackup(plan, volume: v, destination: dest, progress: { p in
            let now = ContinuousClock.now
            // Selalu teruskan update terakhir; selain itu maksimal 10x/detik.
            if now - last >= .milliseconds(100) || p.filesDone == p.filesTotal { last = now; emit(p) }
        }, isCancelled: { flag.withLock { $0 } })
    }
}

extension BrowserModel {
    static func pickFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Pilih"; p.message = "Pilih folder tujuan backup"
        return p.runModal() == .OK ? p.url : nil
    }

    func startBackup() {
        guard let v = selected?.volume else { return }
        if settings.destination == nil {
            guard let url = Self.pickFolder() else { return }
            settings.destination = url.path
        }
        backup = BackupSession(model: self, volume: v, root: root, selection: settings.selection)
    }
}

private func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }

struct BackupSheet: View {
    let session: BackupSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch session.phase {
            case .planning:
                ProgressView("Membuat rencana…").frame(maxWidth: .infinity)
                HStack { Spacer(); Button("Tutup") { session.close() } }
            case .failed(let msg):
                Text(msg)
                destinationRow
                HStack { Spacer(); Button("Tutup") { session.close() } }
            case .preview(let plan):
                PreviewView(session: session, plan: plan)
            case .running:
                RunningView(session: session)
            case .report(let r):
                ReportView(session: session, report: r)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(true)   // sheet hanya ditutup lewat tombolnya (saat jalan: Batal -> laporan)
    }

    var destinationRow: some View {
        HStack {
            Text("Tujuan: \(session.destination?.path ?? "—")").lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Ganti tujuan…") { session.changeDestination() }
        }
    }
}

private extension BackupSheet {
    struct PreviewView: View {
        let session: BackupSession
        let plan: BackupPlan
        var body: some View {
            let c = plan.counts
            let nothing = c.copy + c.conflict == 0
            Text("Pratinjau backup").font(.headline)
            Text("\(plan.items.count) dipilih → \(c.copy) baru (\(bytes(plan.bytesToCopy))), \(c.skip) dilewati, \(c.conflict) konflik, \(c.fail) gagal")
            if !plan.missingSelections.isEmpty {
                Text("hilang: \(plan.missingSelections.count)").foregroundStyle(.orange)
                List(plan.missingSelections, id: \.self) { Text("hilang: \($0)") }.frame(height: 80)
            }
            HStack {
                Text("Tujuan: \(session.destination?.path ?? "—")").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Ganti tujuan…") { session.changeDestination() }
            }
            Text("Ruang kosong: \(bytes(UInt64(max(plan.availableBytes, 0))))")
            if !plan.hasEnoughSpace {
                Text("Ruang kosong di tujuan tidak cukup.").foregroundStyle(.red)
            } else if nothing {
                Text("Tidak ada yang perlu disalin").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Tutup") { session.close() }.keyboardShortcut(.cancelAction)
                Button("Mulai") { session.start(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plan.hasEnoughSpace || nothing)   // pilihan: nonaktif jika tak ada yang disalin
            }
        }
    }

    struct RunningView: View {
        let session: BackupSession
        var body: some View {
            let p = session.progress
            Text("Menyalin…").font(.headline)
            ProgressView(value: p.map { $0.bytesTotal == 0 ? 0 : Double($0.bytesDone) / Double($0.bytesTotal) } ?? 0)
            Text("File \(p?.filesDone ?? 0)/\(p?.filesTotal ?? 0) · \(bytes(p?.bytesDone ?? 0)) / \(bytes(p?.bytesTotal ?? 0))")
            Text("Kecepatan: \(speedText) · Sisa waktu: \(etaText)")
            Text(p?.currentPath ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                Spacer()
                Button(session.cancelling ? "Membatalkan…" : "Batal") { session.cancel() }
                    .disabled(session.cancelling)
            }
        }
        var speedText: String {
            session.speed.map { "\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))/d" } ?? "—"
        }
        var etaText: String {
            guard let s = session.speed, s > 0, let p = session.progress else { return "—" }
            let secs = Int(Double(p.bytesTotal - min(p.bytesDone, p.bytesTotal)) / s)
            return secs >= 60 ? "\(secs / 60) mnt \(secs % 60) d" : "\(secs) d"
        }
    }

    struct ReportView: View {
        let session: BackupSession
        let report: BackupReport
        var body: some View {
            Text("Laporan backup").font(.headline)
            if let r = report.stopReason { Text(reason(r)).foregroundStyle(.red) }
            Text("Disalin: \(report.copied.count) · Dilewati: \(report.skipped) · Konflik: \(report.conflicts.count) · Gagal: \(report.failures.count)")
            if !report.conflicts.isEmpty || !report.failures.isEmpty {
                List {
                    ForEach(report.conflicts.indices, id: \.self) { i in
                        Text("konflik: \(report.conflicts[i].source) → \(report.conflicts[i].dest)")
                    }
                    ForEach(report.failures.indices, id: \.self) { i in
                        Text("gagal: \(report.failures[i].path) — \(report.failures[i].message)")
                    }
                }.frame(height: 140)
            }
            HStack {
                Button("Simpan laporan…") { save() }
                Spacer()
                Button("Tutup") { session.close() }.keyboardShortcut(.defaultAction)
            }
        }
        func reason(_ e: Ext4Error) -> String {
            switch e {
            case .diskDisconnected: "Disk terputus"
            case .destinationFull: "Disk tujuan penuh"
            case .cancelled: "Dibatalkan"
            case .destinationMissing: "Folder tujuan tidak ditemukan"
            default: "Berhenti: \(e)"
            }
        }
        func save() {
            let p = NSSavePanel()
            p.allowedContentTypes = [.plainText]
            p.nameFieldStringValue = "laporan-backup.txt"
            guard p.runModal() == .OK, let url = p.url else { return }
            try? report.text().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
