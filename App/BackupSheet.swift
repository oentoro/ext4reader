import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os
import Ext4Kit

/// Satu sesi salin: pratinjau -> progress -> laporan. Dimiliki BrowserModel selama sheet terbuka.
/// Terikat pada source, volume, pilihan dan tujuan saat dibuat; tidak ikut berganti
/// jika disk lain dipilih di sidebar.
@MainActor @Observable final class BackupSession {
    enum Phase {
        case planning
        case preview(BackupPlan)
        case failed(String)
        case unclean                   // disk kotor; pengguna bisa memilih "Salin tetap"
        case running
        case report(BackupReport)
    }
    var phase: Phase = .planning
    var progress: BackupProgress?
    var speed: Double?                 // byte/detik, rata-rata bergerak 5 detik
    var cancelling = false
    private(set) var destination: URL
    private(set) var sourceGone = false

    let sourceID: String
    private unowned let model: BrowserModel
    private let volume: Volume
    private let selection: Selection
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)   // dibaca dari actor LwExt4
    private var samples: [(t: ContinuousClock.Instant, bytes: UInt64)] = []
    private var planTask: Task<Void, Never>?
    private var allowUnclean = false

    private static let goneMessage = "Disk terputus. Colok lagi disk sumber lalu buka ulang."

    init(model: BrowserModel, sourceID: String, volume: Volume, selection: Selection, destination: URL) {
        self.model = model; self.sourceID = sourceID
        self.volume = volume; self.selection = selection; self.destination = destination
        replan()
    }

    var isRunning: Bool { if case .running = phase { true } else { false } }

    func replan() {
        planTask?.cancel()
        if sourceGone { phase = .failed(Self.goneMessage); return }
        let dest = destination
        phase = .planning
        let (v, r, s, u) = (volume, "/", selection, allowUnclean)
        planTask = Task {
            let res = await Self.plan(v, r, s, dest, u)
            if Task.isCancelled || sourceGone { return }
            switch res {
            case .success(let p): phase = .preview(p)
            case .failure(.notClean): phase = .unclean
            case .failure(.destinationMissing): phase = .failed("Folder tujuan tidak ditemukan. Colok disk tujuan atau pilih folder lain.")
            case .failure(let e): phase = .failed("Gagal membuat rencana salin: \(e)")
            }
        }
    }

    func copyAnyway() { allowUnclean = true; replan() }

    func changeDestination() {
        guard !sourceGone, let url = BrowserModel.pickFolder() else { return }
        destination = url
        replan()
    }

    /// Source sesi ini dilepas/ditutup: hentikan backup yang jalan, atau tampilkan galat.
    func sourceRemoved() {
        sourceGone = true
        switch phase {
        case .running: cancel()
        case .report: break
        default: planTask?.cancel(); phase = .failed(Self.goneMessage)
        }
    }

    func start(_ plan: BackupPlan) {
        guard !sourceGone else { return }
        let dest = destination
        phase = .running; progress = nil; speed = nil; cancelling = false; samples = []
        cancelFlag.withLock { $0 = false }
        let (v, flag) = (volume, cancelFlag)
        // Stream menjaga urutan update progress saat pindah ke main actor.
        let (updates, sink) = AsyncStream.makeStream(of: BackupProgress.self)
        Task {
            let consumer = Task { for await p in updates { received(p) } }
            let report = await Self.run(plan, v, dest, flag) { sink.yield($0) }
            sink.finish()
            await consumer.value             // habiskan update yang tersisa, berurutan
            phase = .report(report)
        }
    }

    func cancel() { cancelling = true; cancelFlag.withLock { $0 = true } }

    private func received(_ p: BackupProgress) {
        guard isRunning else { return }   // update terlambat setelah laporan
        if let cur = progress, p.bytesDone < cur.bytesDone { return }   // sampel basi
        progress = p
        let now = ContinuousClock.now
        samples.append((now, p.bytesDone))
        samples.removeAll { now - $0.t > .seconds(5) }
        if let f = samples.first, let l = samples.last, l.t > f.t {
            let dt = Double((l.t - f.t).components.seconds) + Double((l.t - f.t).components.attoseconds) / 1e18
            let db = Double(l.bytes) - Double(f.bytes)
            if db < 0 { samples = [samples.last!]; speed = nil } else { speed = db / dt }
        }
    }

    func close() { planTask?.cancel(); model.backup = nil }

    @LwExt4 private static func plan(_ v: Volume, _ root: String, _ sel: Selection, _ dest: URL, _ allowUnclean: Bool)
        -> Result<BackupPlan, Ext4Error> {
        do { return .success(try makePlan(v, root: root, selection: sel, destination: dest, allowUnclean: allowUnclean)) }
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
        p.prompt = "Salin ke sini"; p.message = "Pilih folder tujuan di komputer ini"
        return p.runModal() == .OK ? p.url : nil
    }

    func startBackup() {
        guard let s = selected, let v = s.volume, let url = Self.pickFolder() else { return }
        backup = BackupSession(model: self, sourceID: s.id, volume: v, selection: settings.selection, destination: url)
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
                if !session.sourceGone { destinationRow }
                HStack { Spacer(); Button("Tutup") { session.close() } }
            case .unclean:
                Text("Disk ini tidak dilepas dengan bersih").font(.headline)
                Text("Cara aman: mount lalu umount disk ini sekali di Linux. Jika tetap disalin, sebagian besar file aman, tetapi file yang sedang ditulis sebelum disk dicabut bisa kosong, terpotong, atau versi lama.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Tutup") { session.close() }.keyboardShortcut(.cancelAction)
                    Button("Salin tetap") { session.copyAnyway() }
                }
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
            Text("Tujuan: \(session.destination.path)").lineLimit(1).truncationMode(.middle)
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
            Text("Pratinjau salin").font(.headline)
            Text("\(plan.items.count) dipilih → \(c.copy) baru (\(bytes(plan.bytesToCopy))), \(c.skip) dilewati, \(c.conflict) konflik, \(c.fail) gagal")
            if !plan.missingSelections.isEmpty {
                Text("hilang: \(plan.missingSelections.count)").foregroundStyle(.orange)
                List(plan.missingSelections, id: \.self) { Text("hilang: \($0)") }.frame(height: 80)
            }
            HStack {
                Text("Tujuan: \(session.destination.path)").lineLimit(1).truncationMode(.middle)
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
            Text("Laporan salin").font(.headline)
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
            p.nameFieldStringValue = "laporan-salin.txt"
            guard p.runModal() == .OK, let url = p.url else { return }
            try? report.text().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
