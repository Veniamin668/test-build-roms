#!/usr/bin/env bash
# Stage 1 port: system от донора (MIUI 11, A10) + vendor/boot/dtbo/прошивки от базы 9C (A10, vendor 29).
# Пересобираем только system. product и vendor остаются от базы как есть.
set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${DONOR_URL:?DONOR_URL is required}"

REPO="$PWD"
W="$REPO/work"
OUT="$REPO/out"
mkdir -p "$W" "$OUT"
cd "$W"

log() { echo "::group::$*"; }
endlog() { echo "::endgroup::"; }

dl() { curl -L --fail --retry 3 --retry-delay 5 -o "$2" "$1"; }

# ---------- 1. скачать ----------
log "download"
dl "$BASE_URL" base.zip
dl "$DONOR_URL" donor.zip
ls -lh base.zip donor.zip
df -h /
endlog

# ---------- 2. распаковать архивы ----------
log "unzip"
mkdir -p base donor pkg
unzip -q base.zip -d base
unzip -q donor.zip -d donor
echo "--- base:";  ls -la base
echo "--- donor:"; ls -la donor
endlog

# ---------- 3. инструменты для dat <-> img ----------
log "tools"
git clone --depth 1 https://github.com/xpirt/sdat2img.git
git clone --depth 1 https://github.com/xpirt/img2sdat.git
endlog

# распаковка раздела: .new.dat.br -> .new.dat -> .img (raw ext4)
unpack() {
  local d="$1" n="$2"
  if [ -f "$d/$n.new.dat.br" ]; then
    brotli -dfk "$d/$n.new.dat.br" -o "$d/$n.new.dat"
  fi
  if [ -f "$d/$n.new.dat" ]; then
    python3 sdat2img/sdat2img.py "$d/$n.transfer.list" "$d/$n.new.dat" "$d/$n.img"
    rm -f "$d/$n.new.dat"
  fi
  if [ ! -f "$d/$n.img" ]; then
    echo "ERROR: не нашёл образ $n в $d (ни .new.dat.br, ни .new.dat, ни .img)"
    ls -la "$d"
    exit 1
  fi
}

# корень system: у system-as-root образа лежит в <mnt>/system, иначе прямо в <mnt>
sysroot() {
  if [ -f "$1/system/build.prop" ]; then echo "$1/system"; else echo "$1"; fi
}

log "unpack system (base + donor)"
unpack base system
unpack donor system
file base/system.img donor/system.img || true
endlog

# ---------- 4. смонтировать и скопировать system донора в staging ----------
log "mount + stage"
mkdir -p mnt_base mnt_donor stage
sudo mount -o loop,ro base/system.img mnt_base
sudo mount -o loop,ro donor/system.img mnt_donor

sudo rsync -aHAX mnt_donor/ stage/

BASE_ROOT="$(sysroot "$W/mnt_base")"
STAGE_ROOT="$(sysroot "$W/stage")"
echo "BASE_ROOT=$BASE_ROOT"
echo "STAGE_ROOT=$STAGE_ROOT"
endlog

# ---------- 5. патчи ----------
log "patches"
sudo env BASE_ROOT="$BASE_ROOT" STAGE_ROOT="$STAGE_ROOT" REPO="$REPO" bash "$REPO/patches/apply.sh"
endlog

# ---------- 6. собрать новый system.img ----------
log "build system image"
used=$(sudo du -sb stage | cut -f1)
# +15% и +200 МБ запас, выравнивание по 4096
size=$(( (used * 115 / 100 + 200 * 1024 * 1024) / 4096 * 4096 ))
echo "used=$used size=$size"
truncate -s "$size" system_new.img
sudo mke2fs -q -t ext4 -b 4096 -i 8192 -m 0 -L system -O ^has_journal -d stage system_new.img
sudo e2fsck -fn system_new.img || true

sudo umount mnt_base mnt_donor
endlog

# ---------- 7. img -> dat.br ----------
log "img2sdat"
mkdir -p dat
python3 img2sdat/img2sdat.py system_new.img -o dat -v 4 -p system
brotli -f -q 6 dat/system.new.dat -o dat/system.new.dat.br
ls -lh dat
endlog

# ---------- 8. собрать пакет на основе базы ----------
log "assemble package"
unzip -q -o base.zip -d pkg
cp dat/system.new.dat.br pkg/system.new.dat.br
cp dat/system.transfer.list pkg/system.transfer.list
cp dat/system.patch.dat pkg/system.patch.dat

# размер system в dynamic_partitions_op_list
newsize=$(stat -c %s system_new.img)
sed -i -E "s/^(resize system )[0-9]+/\1${newsize}/" pkg/dynamic_partitions_op_list
echo "--- dynamic_partitions_op_list:"
cat pkg/dynamic_partitions_op_list

python3 - "pkg/dynamic_partitions_op_list" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
g = re.search(r'^add_group \S+ (\d+)', t, re.M)
r = [int(x) for x in re.findall(r'^resize \S+ (\d+)', t, re.M)]
print("group max:", g.group(1) if g else "n/a", "| sum of partitions:", sum(r))
if g and sum(r) > int(g.group(1)):
    sys.exit("ERROR: разделы не влезают в группу super. Уменьши system (чисти лишние приложения в patches/remove.txt)")
PY

# отключаем AVB-проверку во всех vbmeta (флаги в big-endian по смещению 120..123)
python3 - pkg/vbmeta*.img <<'PY'
import sys
for p in sys.argv[1:]:
    b = bytearray(open(p, "rb").read())
    if b[:4] != b"AVB0":
        print("skip (not AVB):", p)
        continue
    b[123] = 3  # HASHTREE_DISABLED | VERIFICATION_DISABLED
    open(p, "wb").write(b)
    print("patched:", p)
PY

( cd pkg && zip -r -1 -q "$OUT/MIUI11-angelican-port.zip" . )
ls -lh "$OUT"
endlog

echo "DONE"
