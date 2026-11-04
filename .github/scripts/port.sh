#!/usr/bin/env bash
# Port MIUI 11 (донор, Android 10) -> Redmi 9C NFC (angelican)
#
#   system  : донор (Xiaomi.eu MIUI 11), патчится apply.sh
#   product : сток 9C; если у донора есть свой product, берётся он. Перепаковывается только если apply.sh что-то в нём изменил
#   vendor  : сток 9C без изменений (монтируется только для чтения, для apply.sh)
#   boot, dtbo, прошивки: из базы, поверх них подменяются файлы из папки firmware/
#
# Переменные окружения: BASE_URL, DONOR_URL (обязательно), MAINT (необязательно)
set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${DONOR_URL:?DONOR_URL is required}"

# Ник мейнтейнера для баннера в рекавери
MAINT="${MAINT:-Veniamin668}"

REPO="$PWD"
W="$REPO/work"
OUT="$REPO/out"
mkdir -p "$W" "$OUT"
cd "$W"

# ---------- красивый лог ----------
C_R=$'\033[0m'; C_G=$'\033[32m'; C_B=$'\033[36m'
log()    { echo "::group::▶ $*"; }
endlog() { echo "::endgroup::"; }
ok()     { echo "${C_G}✔ $*${C_R}"; }
info()   { echo "${C_B}• $*${C_R}"; }
warn()   { echo "::warning::$*"; }

dl() { curl -L --fail --retry 3 --retry-delay 5 -o "$2" "$1"; }

# ---------- функции ----------

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

# то же, но если раздела нет, просто возвращает 1
unpack_opt() {
  local d="$1" n="$2"
  if [ -f "$d/$n.new.dat.br" ] || [ -f "$d/$n.new.dat" ] || [ -f "$d/$n.img" ]; then
    unpack "$d" "$n"
    return 0
  fi
  return 1
}

# корень system: у system-as-root образа лежит в <mnt>/system, иначе прямо в <mnt>
sysroot() {
  if [ -f "$1/system/build.prop" ]; then echo "$1/system"; else echo "$1"; fi
}

mount_ro() {
  mkdir -p "$2"
  sudo mount -o loop,ro "$1" "$2"
}

# собрать ext4-образ из папки: build_ext4 <label> <папка> <образ>; размер в LAST_SIZE
LAST_SIZE=0
build_ext4() {
  local label="$1" dir="$2" img="$3"
  local used files size inodes attempt built=0
  used=$(sudo du -sb "$dir" | cut -f1)
  files=$(sudo find "$dir" | wc -l)
  size=$(( (used * 102 / 100 + 32 * 1024 * 1024 + files * 4096) / 4096 * 4096 ))
  inodes=$(( files * 13 / 10 + 2000 ))
  info "$label: used=$used files=$files inodes=$inodes size=$size"
  for attempt in 1 2 3; do
    rm -f "$img"
    truncate -s "$size" "$img"
    if sudo mke2fs -q -t ext4 -b 4096 -N "$inodes" -m 0 -L "$label" -O ^has_journal -d "$dir" "$img"; then
      built=1
      break
    fi
    warn "$label: mke2fs не уместился (попытка $attempt), увеличиваю размер на 5%"
    size=$(( size * 105 / 100 / 4096 * 4096 ))
  done
  [ "$built" = 1 ] || { echo "ERROR: не удалось собрать образ $label"; exit 1; }
  sudo e2fsck -fn "$img" || true
  LAST_SIZE=$(stat -c %s "$img")
  ok "$label: образ собран, $(numfmt --to=iec "$LAST_SIZE")"
}

# raw ext4 -> dat.br: pack_dat <имя раздела> <образ>
pack_dat() {
  local n="$1" img="$2"
  local sparse="${img%.img}.sparse.img"
  mkdir -p dat
  img2simg "$img" "$sparse"
  python3 img2sdat/img2sdat.py "$sparse" -o dat -v 4 -p "$n"
  brotli -f -q 6 "dat/$n.new.dat" -o "dat/$n.new.dat.br"
  rm -f "$sparse" "dat/$n.new.dat"
  ok "$n: dat.br готов"
}

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
rm -f donor.zip
echo "--- base:";  ls -la base
echo "--- donor:"; ls -la donor
endlog

# ---------- 3. инструменты для dat <-> img ----------
log "tools"
git clone --depth 1 https://github.com/xpirt/sdat2img.git
git clone --depth 1 https://github.com/xpirt/img2sdat.git
sed -i 's/^import imp$/import importlib/' img2sdat/*.py
grep -n "imp\." img2sdat/*.py || true
endlog

# ---------- 4. распаковать разделы ----------
log "unpack partitions"
unpack base system
unpack base product
unpack base vendor
unpack donor system
HAVE_DONOR_PRODUCT=0
if unpack_opt donor product; then
  HAVE_DONOR_PRODUCT=1
  ok "у донора есть свой product"
else
  info "у донора нет product, будет использован сток 9C"
fi
rm -f base/*.new.dat.br donor/*.new.dat.br
file base/system.img base/product.img base/vendor.img donor/system.img || true
df -h /
endlog

# ---------- 5. смонтировать и подготовить staging ----------
log "mount + stage"
mkdir -p stage stage_product
mount_ro base/system.img  mnt_base
mount_ro base/product.img mnt_base_product
mount_ro base/vendor.img  mnt_base_vendor
mount_ro donor/system.img mnt_donor

sudo rsync -aHAX mnt_donor/ stage/

if [ "$HAVE_DONOR_PRODUCT" = 1 ]; then
  mount_ro donor/product.img mnt_donor_product
  sudo rsync -aHAX mnt_donor_product/ stage_product/
  DONOR_PRODUCT_ROOT="$W/mnt_donor_product"
else
  sudo rsync -aHAX mnt_base_product/ stage_product/
  DONOR_PRODUCT_ROOT=""
fi

BASE_ROOT="$(sysroot "$W/mnt_base")"
STAGE_ROOT="$(sysroot "$W/stage")"
BASE_PRODUCT_ROOT="$W/mnt_base_product"
STAGE_PRODUCT_ROOT="$W/stage_product"
BASE_VENDOR_ROOT="$W/mnt_base_vendor"
echo "BASE_ROOT=$BASE_ROOT"
echo "STAGE_ROOT=$STAGE_ROOT"
echo "BASE_PRODUCT_ROOT=$BASE_PRODUCT_ROOT"
echo "DONOR_PRODUCT_ROOT=${DONOR_PRODUCT_ROOT:-<нет>}"
echo "STAGE_PRODUCT_ROOT=$STAGE_PRODUCT_ROOT"
echo "BASE_VENDOR_ROOT=$BASE_VENDOR_ROOT"
endlog

# ---------- 6. патчи ----------
log "patches"
sudo env \
  BASE_ROOT="$BASE_ROOT" \
  STAGE_ROOT="$STAGE_ROOT" \
  BASE_PRODUCT_ROOT="$BASE_PRODUCT_ROOT" \
  DONOR_PRODUCT_ROOT="$DONOR_PRODUCT_ROOT" \
  STAGE_PRODUCT_ROOT="$STAGE_PRODUCT_ROOT" \
  BASE_VENDOR_ROOT="$BASE_VENDOR_ROOT" \
  REPO="$REPO" \
  bash "$REPO/.github/scripts/apply.sh"
endlog

# ---------- 7. изменился ли product ----------
log "product change check"
PRODUCT_CHANGED=0
if [ "$HAVE_DONOR_PRODUCT" = 1 ]; then
  PRODUCT_CHANGED=1
  info "product донора, перепаковка обязательна"
elif sudo diff -rq mnt_base_product stage_product > product.diff 2>&1; then
  info "product не изменился, остаётся стоковый образ"
else
  PRODUCT_CHANGED=1
  warn "apply.sh изменил product, он будет перепакован"
  head -n 40 product.diff || true
fi
endlog

# ---------- 8. размонтировать и освободить место ----------
log "umount"
sudo umount mnt_base mnt_base_product mnt_base_vendor mnt_donor
if [ "$HAVE_DONOR_PRODUCT" = 1 ]; then sudo umount mnt_donor_product; fi
rm -f base/*.img donor/*.img
df -h /
endlog

# ---------- 9. собрать system ----------
log "build system image"
build_ext4 system stage system_new.img
SYS_SIZE="$LAST_SIZE"
pack_dat system system_new.img
ls -lh dat
endlog

# ---------- 10. собрать product (если менялся) ----------
PROD_SIZE=0
if [ "$PRODUCT_CHANGED" = 1 ]; then
  log "build product image"
  build_ext4 product stage_product product_new.img
  PROD_SIZE="$LAST_SIZE"
  pack_dat product product_new.img
  ls -lh dat
  endlog
fi

# ---------- 11. собрать пакет на основе базы ----------
log "assemble package"
unzip -q -o base.zip -d pkg
cp dat/system.new.dat.br pkg/system.new.dat.br
cp dat/system.transfer.list pkg/system.transfer.list
cp dat/system.patch.dat pkg/system.patch.dat
ok "system подставлен в пакет"
if [ "$PRODUCT_CHANGED" = 1 ]; then
  cp dat/product.new.dat.br pkg/product.new.dat.br
  cp dat/product.transfer.list pkg/product.transfer.list
  cp dat/product.patch.dat pkg/product.patch.dat
  ok "product подставлен в пакет"
else
  info "product в пакете остаётся стоковым"
fi
endlog

# ---------- 11a. подмена прошивок из папки firmware/ ----------
log "firmware overrides"
shopt -s nullglob
if [ -d "$REPO/firmware" ]; then
  for f in "$REPO"/firmware/*; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    case "$n" in README*|.gitkeep) continue ;; esac
    if [ -f "pkg/$n" ]; then
      old=$(sha256sum "pkg/$n" | cut -c1-12)
      new=$(sha256sum "$f" | cut -c1-12)
      if [ "$old" = "$new" ]; then
        info "$n: совпадает со стоком ($old), пропуск"
      else
        cp "$f" "pkg/$n"
        ok "$n: заменён ($old -> $new)"
      fi
    else
      warn "$n: такого файла нет в базе, пропущен"
    fi
  done
else
  info "папки firmware/ нет, прошивки остаются стоковыми"
fi
shopt -u nullglob
endlog

# ---------- 11b. брендинг updater-script (баннер и мейнтейнер) ----------
log "updater-script branding"
US=pkg/META-INF/com/google/android/updater-script
BANNER=""
for c in "$REPO/patches/banner.txt" "$REPO/.github/scripts/banner.txt"; do
  if [ -f "$c" ]; then BANNER="$c"; break; fi
done

{
  if [ -n "$BANNER" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      line=${line//\\/\/}
      line=${line//\"/\'}
      line=${line//@MAINT@/$MAINT}
      [ -z "$line" ] && line=" "
      printf 'ui_print("%s");\n' "$line"
    done < "$BANNER"
  else
    printf 'ui_print("MIUI 11 port for Redmi 9C NFC");\n'
    printf 'ui_print("Maintainer: %s");\n' "$MAINT"
  fi
  printf 'ui_print("Build     : %s");\n' "$(date -u +%F)"
  printf 'ui_print(" ");\n'
} > banner.edify

sed -i 's|^ui_print("Target:.*|ui_print("MIUI 11 port, base 12.0.16.0");|' "$US"
sed -i '1r banner.edify' "$US"
if [ -n "$BANNER" ]; then ok "баннер добавлен из $BANNER"; else info "banner.txt не найден, добавлена короткая шапка"; fi
echo "--- начало updater-script:"
head -n 30 "$US"
endlog

# ---------- 11c. размеры разделов и проверка super ----------
log "dynamic partitions"
sed -i -E "s/^(resize system )[0-9]+/\1${SYS_SIZE}/" pkg/dynamic_partitions_op_list
if [ "$PRODUCT_CHANGED" = 1 ]; then
  sed -i -E "s/^(resize product )[0-9]+/\1${PROD_SIZE}/" pkg/dynamic_partitions_op_list
fi
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
ok "разделы влезают в super"
endlog

# ---------- 11d. отключаем AVB-проверку во всех vbmeta ----------
log "vbmeta"
# флаги big-endian по смещению 120..123
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
endlog

# ---------- 12. упаковка ----------
log "zip"
( cd pkg && zip -r -1 -q "$OUT/MIUI11-angelican-port.zip" . )
ls -lh "$OUT"
ok "zip собран"
endlog

# ---------- сводка для страницы запуска ----------
{
  echo "## MIUI 11 port"
  echo "| параметр | значение |"
  echo "|---|---|"
  echo "| system | $(numfmt --to=iec "$SYS_SIZE") |"
  if [ "$PRODUCT_CHANGED" = 1 ]; then
    echo "| product | перепакован, $(numfmt --to=iec "$PROD_SIZE") |"
  else
    echo "| product | сток |"
  fi
  echo "| zip | $(du -h "$OUT"/MIUI11-angelican-port.zip | cut -f1) |"
  echo "| sha256 | $(sha256sum "$OUT"/MIUI11-angelican-port.zip | cut -d' ' -f1) |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

ok "DONE"
