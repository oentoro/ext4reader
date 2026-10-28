# ext4 Reader untuk macOS — Desain

Tanggal: 2026-10-29
Status: draft, menunggu persetujuan

## 1. Maksud & alasan

Pemilik punya SSD ext4 yang biasa terpasang di server Debian 13 (trixie) sebagai
penyimpanan library Immich. Ia ingin mencolokkan SSD itu ke Mac lalu **membackup
foto/video pilihan** ke Mac, dan bisa memilih sendiri file/folder mana yang dibackup.
Backup dilakukan berulang ke tujuan yang sama, jadi hanya file baru yang disalin.

macOS tidak bisa membaca ext4. Solusi yang ada butuh driver berbayar atau macFUSE/kernel
extension. Yang diinginkan adalah app Mac native yang berdiri sendiri.

Kemampuan menulis ke ext4 tetap diinginkan untuk disk ext4 biasa (bukan SSD Immich), walau
jarang dipakai. Fitur ini dibangun sebagai tahap kedua.

Susunan data SSD Immich (Storage Template aktif, `{{y}}/{{MM}}/{{dd}}/{{filename}}`):

```
<root>/immich/library/library/admin/2026/08/01/IMG_5772.heic
                              user  thn  bln tgl
```

## 2. Tujuan

Tahap 1, membaca (prioritas, harus bisa dipakai lebih dulu):
- Mendeteksi disk ext4 yang dicolok (seluruh disk maupun partisi), lalu membukanya **read-only**.
- Menjelajahi folder dalam pohon dengan centang (layout "A", lihat §5).
- Backup bertahap pilihan ke folder tujuan di Mac (lihat §6).
- Bisa juga membuka **file image ext4** (`.img`) dengan jalur kode yang sama. Ini dibutuhkan
  untuk pengujian dan berguna untuk image backup.

Tahap 2, menulis (disk ext4 biasa saja):
- Menyalin file dari Mac ke disk, menghapus, mengganti nama, dan membuat folder.
- Dengan pengaman pada §7.

## 3. Bukan tujuan

- Mount di Finder (FSKit, macFUSE, kext).
- Thumbnail/preview foto. Struktur tanggal sudah cukup untuk memilih.
- Memahami database Immich.
- Sinkronisasi cermin: file yang hilang dari SSD **tidak** dihapus dari tujuan.
- Penjadwalan otomatis, App Store, notarization.
- LVM, RAID/mdadm, LUKS/enkripsi. Disk seperti itu cukup ditampilkan sebagai "tidak didukung".
- Menyalin permission/owner Linux ke Mac.

## 4. Anti-tujuan (gagal walau "berfungsi")

- **Ada byte yang tertulis ke disk saat mode read-only.** Ini dijamin oleh OS: di mode baca,
  device dibuka dengan `O_RDONLY`, sehingga bukan hanya dijaga oleh logika app.
- Backup menimpa atau menghapus file yang sudah ada di tujuan.
- Backup yang dibatalkan atau gagal meninggalkan file setengah jadi dengan nama final.
- Disk ext4 rusak setelah operasi tulis (`e2fsck -fn` harus bersih).
- Mode tulis aktif di SSD Immich.

## 5. Tampilan (layout A, dipilih pemilik)

- **Sidebar:** daftar disk/partisi ext4 dan image yang dibuka, dengan label, ukuran, dan status
  (🔒 read-only / ✏️ bisa ditulis / ⚠️ tidak dilepas dengan bersih / ⛔ tidak didukung).
- **Area utama:** pohon folder (expand/collapse) dengan centang per folder dan file. Kolom yang
  ditampilkan: nama, ukuran, tanggal ubah. Status centang: ☐ / ☑ / ◩ (sebagian). Mencentang
  folder berarti memilih seluruh isinya, termasuk file yang belum pernah dibuka.
- **Breadcrumb** path di atas.
- **Bar bawah:** "Dipilih: N file · X GB" dan tombol **Backup ke…**. Hitungan folder yang
  dicentang dihitung di background; selama dihitung, tampil "menghitung…".
- Isi folder dimuat malas (lazy) saat folder dibuka, karena library bisa berisi puluhan ribu file.

## 6. Backup (bertahap)

1. Pilih folder tujuan (NSOpenPanel).
2. **Pratinjau:** app memindai pilihan vs tujuan, lalu menampilkan ringkasan, misalnya
   "1.312 dipilih → 87 baru (1,2 GB), 1.225 dilewati, 2 konflik", plus cek ruang kosong tujuan.
   Kalau ruang tidak cukup, backup tidak bisa dimulai.
3. **Aturan per file.** Path di tujuan = path relatif terhadap **akar backup** disk itu (lihat
   §6a). Contoh dengan akar `immich/library/library`:
   `immich/library/library/admin/2026/08/01/IMG_5772.heic` → `Tujuan/admin/2026/08/01/IMG_5772.heic`.
   - Tujuan belum ada → salin.
   - Ada dan ukuran sama **dan** mtime sama (toleransi ±2 detik, karena resolusi exFAT) → lewati.
   - Ada tapi beda → **jangan timpa**. Kalau salinan konflik sebelumnya (`IMG_5772 (2).heic`,
     `(3)`, …) sudah ada dengan ukuran+mtime yang cocok, file dilewati. Kalau tidak, simpan
     sebagai `(n)` berikutnya yang masih kosong dan catat sebagai konflik di laporan. Jadi
     jalankan ulang tanpa perubahan = semua dilewati *(keputusan saya)*.
   - **Tabrakan huruf besar/kecil:** ext4 case-sensitive, sedangkan APFS default tidak. Kalau
     `A.jpg` dan `a.jpg` ada di folder yang sama, file kedua diperlakukan sebagai konflik dengan
     aturan yang sama.
4. **Penyalinan:** tulis ke `.<nama>.partial`, set mtime dari inode sumber, lalu rename atomik ke
   nama final. Saat batal atau error, `.partial` dihapus.
5. **Progress:** jumlah file, byte, kecepatan, sisa waktu, tombol Batal.
6. **Error per file** (gagal baca, nama bukan UTF-8 valid, dll.) dicatat. Backup lanjut ke file
   berikutnya. Di akhir tampil laporan: disalin / dilewati / konflik / gagal, dan bisa disimpan
   sebagai `.txt`.
7. **Jenis file:** hanya file biasa dan direktori. Symlink, device, fifo, dan socket dilewati dan
   dicatat di laporan *(keputusan saya; Immich tidak memakainya)*.
8. Tidak ada manifest file. Status "sudah dibackup" ditentukan murni dari isi folder tujuan.
9. **Disk tidak dilepas bersih → backup diblokir** (menjelajah tetap boleh, dengan peringatan).
   Pesan: "Mount lalu umount disk ini sekali di Linux." Pemilik biasanya melepas SSD lewat
   `umount`, jadi kasus ini jarang.

## 6a. Akar backup & pilihan yang diingat (diputuskan pemilik)

- **Akar backup** ditetapkan per disk (klik kanan folder → "Jadikan akar backup"). Pohon tetap
  menampilkan seluruh disk, tapi centang hanya bisa diberikan di dalam akar. Akar ditandai di
  pohon dan breadcrumb.
- Kalau struktur Immich terdeteksi, app **menyarankan** akar = folder `library/library` (folder
  yang berisi folder user), dan pemilik mengonfirmasi *(keputusan saya)*.
- **Diingat per disk** (dikenali dari UUID file system ext4): akar backup, folder tujuan, dan
  pilihan centang. Disimpan di Application Support sebagai JSON *(keputusan saya)*.
- **Model pilihan:** daftar path yang dicentang + daftar pengecualian (path yang dibuka centangnya
  di dalam folder yang dicentang). Folder yang dicentang otomatis mencakup isi baru seperti
  folder tanggal baru di sesi berikutnya.
- Path tersimpan yang sudah tidak ada di disk ditampilkan di pratinjau sebagai "hilang" dan
  tidak dianggap error.
- Mengganti akar backup setelah pernah backup memicu peringatan bahwa file akan dianggap baru
  di tujuan yang sama.
- Alur rutin: colok → buka disk → pilihan & tujuan sudah terisi → **Backup** → pratinjau → mulai.

## 7. Menulis (tahap 2)

- Mati secara default. Diaktifkan per disk lewat tombol, dengan dialog konfirmasi yang
  menyarankan membuat backup dulu. Setelah diaktifkan, device dibuka ulang dengan `O_RDWR`.
- **Ditolak otomatis** (disk tetap bisa dibaca) jika:
  - superblock menandakan disk tidak dilepas dengan bersih / journal perlu recovery;
  - ada fitur `incompat` atau `ro_compat` yang tidak ada di daftar fitur yang terbukti didukung
    lwext4 (daftar eksplisit di kode, bukan "semua yang dikenal");
  - **struktur Immich terdeteksi:** ada file penanda `.immich` (Immich menaruhnya di folder
    storage-nya) atau folder `upload`/`thumbs`/`encoded-video` bersaudara di 4 level teratas.
    Penguncian berlaku untuk seluruh disk, bukan peringatan biasa.
- **Operasi:** salin dari Mac (tombol + drag-and-drop ke folder), hapus (konfirmasi dengan daftar
  isi, ditegaskan bahwa ini permanen), ganti nama, buat folder.
- Semua operasi berjalan lewat journal lwext4 (transaksi).
- **Target:** disk dengan format default `mkfs.ext4` Debian trixie harus bisa ditulis, karena
  disk "biasa" pemilik kemungkinan besar dibuat seperti itu. Menambal jalur tulis lwext4
  (misalnya `metadata_csum`, `orphan_file`) termasuk lingkup tahap 2. Allow-list fitur hanya
  diperluas setelah fitur itu lulus uji `e2fsck -fn` *(keputusan saya)*.
- File/folder baru mewarisi uid/gid dan mode dasar dari folder induk *(keputusan saya, supaya file
  tidak jadi milik root di Linux)*.
- Disk dilepas bersih (flush + umount lwext4) sebelum app menutup atau disk di-eject.

## 8. Arsitektur (keputusan teknis)

- **Swift + SwiftUI**, macOS 14+, universal (Apple Silicon + Intel). Proyek Xcode, build sendiri,
  **tanpa sandbox**.
- **lwext4** (C) di-vendor sebagai source di repo, dipin ke satu commit, lalu dijembatani ke
  Swift lewat module map. Ext4 tidak diimplementasikan dari nol.
  - lwext4 tidak thread-safe, jadi semua panggilan diserialkan lewat satu actor/queue per disk.
  - Block device lwext4 diisi callback baca/tulis ke file descriptor. Raw device (`/dev/rdiskN`)
    mewajibkan I/O yang selaras dengan ukuran sektor, jadi callback menangani alignment.
- **Akses disk:** `/dev/rdiskN` hanya bisa dibaca root/operator. Gunakan **`authopen`** bawaan
  macOS (`/usr/libexec/authopen -stdoutpipe`, dengan `-w` hanya untuk mode tulis). Alat ini
  menampilkan dialog password admin dan mengembalikan file descriptor ke app. Tidak perlu
  helper daemon atau SMJobBless.
- **Deteksi disk:** DiskArbitration untuk daftar dan event colok/cabut. Setiap whole disk dan
  partisi dicek magic ext4 (`0xEF53` di offset 1080). Untuk image file, cukup `open()` biasa.
- Saat SSD ext4 dicolok, macOS akan menampilkan dialog "disk tidak dapat dibaca". Pemilik memilih
  **Ignore**. App menampilkan petunjuk ini di layar kosong.
- **Disk tidak dilepas bersih di mode baca:** boleh dijelajahi dengan peringatan, tapi backup
  diblokir (§6 no. 9). Journal **tidak** di-replay, baik ke disk maupun di memori.

## 9. Pengujian

- **Fixture:** image dibuat dengan `mkfs.ext4` dari e2fsprogs 1.47 (Homebrew) dengan default ala
  Debian trixie (`metadata_csum`, `64bit`, `extents`, `flex_bg`, `orphan_file`, dll.). Isinya
  diisi langsung dengan `mkfs.ext4 -d <folder>` dari pohon contoh berbentuk Immich (termasuk
  folder besar dengan ribuan file untuk menguji htree, file >4 GB, nama non-ASCII, dan pasangan
  `A.jpg`/`a.jpg`).
- **Uji baca:** backup dari image, lalu `diff -r` terhadap folder sumber. Jalankan lagi dan
  semuanya harus dilewati. Ubah satu file, lalu pastikan konflik ditangani sesuai §6.
- **Uji tulis (tahap 2):** setiap operasi pada salinan image diikuti `e2fsck -fn` yang harus
  bersih, plus verifikasi isi lewat `debugfs`.
- **Uji jaminan read-only:** hash image sebelum dan sesudah sesi baca + backup harus identik.
- **Uji manual sekali** pada SSD Immich asli (read-only).

## 10. Risiko terbuka (cek di awal tahap 1)

1. **Kompatibilitas lwext4 dengan format default trixie.** Spike pertama: buka image fixture
   trixie dengan lwext4 dan baca seluruh pohon. Kalau gagal pada fitur tertentu, tambal lwext4
   (di-vendor, jadi bisa).
2. **Fitur SSD asli belum diketahui.** Pemilik bisa menjalankan `sudo dumpe2fs -h /dev/sdX1` di
   server untuk melihat daftar fitur dan memastikan disk tidak dibungkus LVM/LUKS.
3. **Lisensi lwext4:** sebagian file mungkin GPLv2, bukan seluruhnya BSD. Tidak masalah untuk
   pemakaian pribadi, tapi harus dicek kalau app akan didistribusikan.
4. **Kecepatan:** targetnya mendekati batas USB/SSD. Ukur di tahap 1. Kalau lambat, perbesar
   ukuran baca dan cache blok lwext4.

## 11. Diserahkan ke builder

Struktur kode, nama tipe, detail UI (ikon, warna, ukuran kolom), format teks laporan, ukuran
buffer, dan cara lwext4 dibangun (target statis di Xcode atau SwiftPM).
