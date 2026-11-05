# Ext4 Reader

Aplikasi macOS untuk membaca SSD/disk **ext4** (Linux) dan menyalin file/folder pilihan ke Mac.
Disk dibuka **read-only**, jadi isinya tidak pernah diubah.

## Fitur

- Mendeteksi disk ext4 eksternal otomatis, termasuk partisi bertipe Linux maupun Microsoft Basic Data.
- Bisa juga membuka file image ext4 (`Buka image…`).
- Centang file/folder → **Salin ke…** → pilih folder tujuan. Folder disalin dengan namanya sendiri, seperti di Finder.
- File yang sudah ada tidak pernah ditimpa: file identik dilewati, nama bentrok jadi `nama (2).ext`.
- Pratinjau sebelum menyalin (jumlah file, ukuran, ruang kosong), progress, kecepatan, sisa waktu, laporan akhir.
- Disk yang tidak dilepas dengan bersih: muncul peringatan dengan pilihan **Salin tetap**.

## Kebutuhan

- macOS 14 atau lebih baru
- Xcode 16 (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & jalankan

```bash
xcodegen generate
xcodebuild -project Ext4Reader.xcodeproj -scheme Ext4Reader -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Ext4Reader.app
```

Atau `open Ext4Reader.xcodeproj` lalu ⌘R di Xcode.

## Cara pakai

1. Colok SSD ext4. Jika macOS bilang disk tidak dapat dibaca, pilih **Ignore**.
2. Di sidebar, klik **Buka** pada disk (🔑), lalu masukkan password admin. Akses raw disk lewat `authopen`.
3. Centang file/folder yang ingin disalin.
4. Klik **Salin ke…**, pilih folder di Mac, cek pratinjau, lalu **Mulai**.

### "Disk ini tidak dilepas dengan bersih"

Journal ext4 masih punya perubahan yang belum ditulis, biasanya karena disk dicabut tanpa unmount.
App read-only tidak bisa memutar ulang journal. Cara aman: di Linux, `mount` lalu `umount` disk sekali.
Atau pilih **Salin tetap**: sebagian besar file aman, tetapi file yang sedang ditulis sebelum disk dicabut bisa rusak.

## Tes

```bash
Tests/Fixtures/make-fixtures.sh   # sekali: membuat image ext4 uji (butuh e2fsprogs dari brew)
swift test
```

## Struktur

| Path | Isi |
|------|-----|
| `App/` | UI SwiftUI, deteksi disk (DiskArbitration), pembuka raw disk (`authopen`) |
| `Sources/Ext4Kit/` | Library Swift: volume, pilihan, perencana & penyalin |
| `Sources/CLwext4/` | [lwext4](https://github.com/gkostka/lwext4) (C) untuk membaca ext4 |
| `Tests/` | Tes Swift Testing + skrip fixture |

## Lisensi

`Sources/CLwext4` berasal dari lwext4: sebagian besar BSD, kecuali `ext4_extent.c` dan `ext4_xattr.c` yang
GPL-2.0-or-later. Lihat `Sources/CLwext4/LICENSE` dan `Sources/CLwext4/VERSION`.
