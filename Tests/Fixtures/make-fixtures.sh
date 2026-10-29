#!/bin/bash
# Builds ext4 test images under Tests/Fixtures/build/. Needs e2fsprogs (brew).
set -euo pipefail
cd "$(dirname "$0")"
E2="$(brew --prefix e2fsprogs 2>/dev/null || echo /opt/homebrew/opt/e2fsprogs)"
[ -x "$E2/sbin/mkfs.ext4" ] || { brew install e2fsprogs; E2="$(brew --prefix e2fsprogs)"; }
B=build
chmod -R u+w "$B" 2>/dev/null || true
rm -rf "$B"; mkdir -p "$B/src"
S="$B/src"

L=$S/immich/library
for d in library upload thumbs encoded-video; do mkdir -p "$L/$d"; : > "$L/$d/.immich"; done
for p in 2026/07/01/IMG_0001 2026/07/02/IMG_0002 2026/08/01/IMG_5772; do
  mkdir -p "$L/library/admin/$(dirname $p)"
  head -c 102400 /dev/urandom > "$L/library/admin/$p.heic"
done
mkdir -p $S/big $S/bigdir $S/names $S/links
truncate -s 5G $S/big/huge.bin
( cd $S/bigdir && seq -f 'f%05g' 0 19999 | xargs touch )
printf 'nfc\n' > "$S/names/café.txt"
ln -s ../names $S/links/l

truncate -s 512M $B/trixie.img
"$E2/sbin/mkfs.ext4" -q -F -b 4096 -I 256 -N 40000 \
  -O has_journal,extent,huge_file,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize,orphan_file \
  -L SSDTEST -U 11111111-2222-3333-4444-555555555555 -d $S $B/trixie.img

printf 'upper\n' > $B/up.tmp; printf 'lower\n' > $B/low.tmp
printf 'nfd\n' > $B/nfd.txt; printf 'bad\n' > $B/bad.txt
cat > $B/cmds <<CMD
write $B/up.tmp names/A.jpg
write $B/low.tmp names/a.jpg
write $B/nfd.txt names/cafe$(printf '\xcc\x81').txt
write $B/bad.txt names/bad$(printf '\xff').txt
CMD
"$E2/sbin/debugfs" -w -f $B/cmds $B/trixie.img >/dev/null
rm $B/cmds $B/up.tmp $B/low.tmp $B/nfd.txt $B/bad.txt

# -U made mkfs enable metadata_csum_seed; real Debian images are unseeded.
"$E2/sbin/tune2fs" -O ^metadata_csum_seed $B/trixie.img >/dev/null

# Small seeded image (keeps metadata_csum_seed) to exercise the seeded path.
mkdir -p $B/seedsrc/a/b; echo hello-seeded > $B/seedsrc/a/b/f.txt; echo top > $B/seedsrc/top.txt
truncate -s 32M $B/seeded.img
"$E2/sbin/mkfs.ext4" -q -F -b 4096 -I 256 \
  -O has_journal,extent,huge_file,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize,orphan_file \
  -L SEEDED -U 11111111-2222-3333-4444-555555555556 -d $B/seedsrc $B/seeded.img
rm -rf $B/seedsrc

cp $B/trixie.img $B/dirty.img
"$E2/sbin/debugfs" -w -R "feature needs_recovery" $B/dirty.img >/dev/null
echo OK
