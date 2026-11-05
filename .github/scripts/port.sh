#!/usr/bin/env bash
# Port MIUI 11 (донор, Android 10) -> Redmi 9C NFC (angelican)
#
#   system  : донор (Xiaomi.eu MIUI 11), патчится apply.sh. Product лежит ВНУТРИ
#             system (/system/product), отдельного раздела product нет
#   product : в пакет не входит. Сток 9C монтируется только для чтения,
#             как источник MTK-файлов для apply.sh
#   vendor  : сток 9C без изменений (монтируется только для чтения)
#   boot, dtbo, прошивки: из базы, поверх них подменяются файлы из папки firmware/
#
# Переменные окружения: BASE_URL, DONOR_URL (обязательно), MAINT (необязательно)
set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${DONOR_URL:?DONOR_URL is required}"

# Ник мейнтейнера для баннера в рекавери
MAINT="${MAINT:-Veniamin668}"

# Лимит GitHub на один файл в релизе: 2 GiB
RELEASE_LIMIT=$((2 * 1024 * 1024 * 1024))

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
if [ -f donor/product.new.dat.br ] || [ -f donor/product.new.dat ] || [ -f donor/product.img ]; then
  warn "у донора есть отдельный product: он игнорируется, product в этой схеме не прошивается"
fi
rm -f base/*.new.dat.br donor/*.new.dat.br
file base/system.img base/product.img base/vendor.img donor/system.img || true
df -h /
endlog

# ---------- 5. смонтировать и подготовить staging ----------
log "mount + stage"
mkdir -p stage
mount_ro base/system.img  mnt_base
mount_ro base/product.img mnt_base_product
mount_ro base/vendor.img  mnt_base_vendor
mount_ro donor/system.img mnt_donor

sudo rsync -aHAX mnt_donor/ stage/

BASE_ROOT="$(sysroot "$W/mnt_base")"
STAGE_ROOT="$(sysroot "$W/stage")"
BASE_PRODUCT_ROOT="$W/mnt_base_product"
BASE_VENDOR_ROOT="$W/mnt_base_vendor"
echo "BASE_ROOT=$BASE_ROOT"
echo "STAGE_ROOT=$STAGE_ROOT"
echo "BASE_PRODUCT_ROOT=$BASE_PRODUCT_ROOT (только чтение, не прошивается)"
echo "BASE_VENDOR_ROOT=$BASE_VENDOR_ROOT"
echo "--- /product в образе донора:"
sudo ls -ld "$W/stage/product" "$STAGE_ROOT/product" 2>&1 || true
endlog

# ---------- 5a. fstab базы: нужен ли product (диагностика, ничего не меняет) ----------
# Сток-vendor может монтировать /product при загрузке. Если у записи product нет
# nofail, а раздела в super не будет, раннее монтирование может не пройти.
log "fstab check (vendor stock)"
sudo sh -c 'for f in mnt_base_vendor/etc/fstab*; do [ -f "$f" ] || continue; echo "--- $f"; grep -v "^#" "$f" | grep -v "^[[:space:]]*$"; done' || true
echo "--- записи с product / odm:"
sudo sh -c 'grep -H -i -E "product|odm" mnt_base_vendor/etc/fstab* 2>/dev/null' || echo "(записей про product/odm в vendor/etc/fstab* нет)"
endlog

# ---------- 6. патчи ----------
log "patches"
sudo env \
  BASE_ROOT="$BASE_ROOT" \
  STAGE_ROOT="$STAGE_ROOT" \
  BASE_PRODUCT_ROOT="$BASE_PRODUCT_ROOT" \
  BASE_VENDOR_ROOT="$BASE_VENDOR_ROOT" \
  REPO="$REPO" \
  bash "$REPO/.github/scripts/apply.sh"
endlog

# ---------- 7. размонтировать и освободить место ----------
log "umount"
sudo umount mnt_base mnt_base_product mnt_base_vendor mnt_donor
rm -f base/*.img donor/*.img
df -h /
endlog

# ---------- 8. собрать system ----------
log "build system image"
build_ext4 system stage system_new.img
SYS_SIZE="$LAST_SIZE"
pack_dat system system_new.img
ls -lh dat
endlog

# ---------- 9. собрать пакет на основе базы ----------
log "assemble package"
unzip -q -o base.zip -d pkg
cp dat/system.new.dat.br pkg/system.new.dat.br
cp dat/system.transfer.list pkg/system.transfer.list
cp dat/system.patch.dat pkg/system.patch.dat
ok "system подставлен в пакет"

# product не прошивается: убираем его из пакета, списка разделов и updater-script
rm -f pkg/product.new.dat.br pkg/product.transfer.list pkg/product.patch.dat
sed -i '/product/d' pkg/dynamic_partitions_op_list
ok "product убран из пакета и из dynamic_partitions_op_list"
endlog

# ---------- 9a. updater-script: убрать блок product ----------
log "updater-script: remove product"
US=pkg/META-INF/com/google/android/updater-script
python3 - "$US" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()

new = re.sub(
    r'# Patch partition product\s*\n.*?Failed to update product image\."\);\s*\n',
    '',
    text,
    count=1,
    flags=re.S,
)

if new == text:
    print("::warning::блок product в updater-script не найден, проверь скрипт вручную")
else:
    open(path, "w", encoding="utf-8").write(new)
    print("блок product удалён из updater-script")

left = [l for l in new.splitlines() if "product" in l.lower()]
print(f"строк с 'product' осталось: {len(left)}")
for l in left:
    print("   ", l)
PY
endlog

# ---------- 9b. подмена прошивок из папки firmware/ ----------
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

# ---------- 9c. брендинг updater-script (баннер и мейнтейнер) ----------
log "updater-script branding"
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

# ---------- 9d. размеры разделов и проверка super ----------
log "dynamic partitions"
sed -i -E "s/^(resize system )[0-9]+/\1${SYS_SIZE}/" pkg/dynamic_partitions_op_list
echo "--- dynamic_partitions_op_list:"
cat pkg/dynamic_partitions_op_list

python3 - "pkg/dynamic_partitions_op_list" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
g = re.search(r'^add_group \S+ (\d+)', t, re.M)
r = [int(x) for x in re.findall(r'^resize \S+ (\d+)', t, re.M)]
print("group max:", g.group(1) if g else "n/a", "| sum of partitions:", sum(r))
if g and sum(r) > int(g.group(1)):
    sys.exit("ERROR: разделы не влезают в группу super. Уменьши system (patches/remove.txt)")
PY
ok "разделы влезают в super"
endlog

# ---------- 9e. отключаем AVB-проверку во всех vbmeta ----------
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

# ---------- 10. упаковка ----------
log "zip"
( cd pkg && zip -r -1 -q "$OUT/MIUI11-angelican-port.zip" . )
ZIP="$OUT/MIUI11-angelican-port.zip"
ZIP_SIZE=$(stat -c %s "$ZIP")
ls -l "$ZIP"
ok "zip собран, ${ZIP_SIZE} байт ($(numfmt --to=iec-i --suffix=B "$ZIP_SIZE"))"
if [ "$ZIP_SIZE" -ge "$RELEASE_LIMIT" ]; then
  warn "zip больше 2 GiB: шаг Publish release упадёт (лимит GitHub на файл в релизе). Файл останется в артефактах"
elif [ "$ZIP_SIZE" -ge $((RELEASE_LIMIT - 100 * 1024 * 1024)) ]; then
  warn "zip в пределах 100 MiB от лимита релиза (2 GiB)"
fi
endlog

# ---------- сводка для страницы запуска ----------
{
  echo "## MIUI 11 port"
  echo "| параметр | значение |"
  echo "|---|---|"
  echo "| system | $(numfmt --to=iec "$SYS_SIZE") |"
  echo "| product | не прошивается (внутри system/product) |"
  echo "| zip | $(numfmt --to=iec-i --suffix=B "$ZIP_SIZE") ($ZIP_SIZE байт) |"
  echo "| лимит релиза 2 GiB | $([ "$ZIP_SIZE" -lt "$RELEASE_LIMIT" ] && echo 'проходит' || echo 'ПРЕВЫШЕН') |"
  echo "| sha256 | $(sha256sum "$ZIP" | cut -d' ' -f1) |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

ok "DONE"
