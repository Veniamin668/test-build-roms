#!/usr/bin/env bash
# Stage 1 port: system от донора (MIUI 11, A10) + vendor/boot/dtbo/прошивки от базы 9C (A10, vendor 29).
# Пересобираем только system. product и vendor остаются от базы как есть.
# Файлы из папки firmware/ в репо подменяют одноимённые файлы в итоговом zip.
set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${DONOR_URL:?DONOR_URL is required}"

# Ник мейнтейнера для баннера в рекавери (можно переопределить переменной MAINT)
MAINT="${MAINT:-ktoya?}"

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
sed -i 's/^import imp$/import importlib/' img2sdat/*.py
grep -n "imp\." img2sdat/*.py || true
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
sudo env BASE_ROOT="$BASE_ROOT" STAGE_ROOT="$STAGE_ROOT" REPO="$REPO" bash "$REPO/.github/scripts/apply.sh"
endlog

# ---------- 6. собрать новый system.img ----------
log "build system image"
used=$(sudo du -sb stage | cut -f1)
# +2% и +48 МБ запас, выравнивание по 4096
size=$(( (used * 102 / 100 + 48 * 1024 * 1024) / 4096 * 4096 ))
echo "used=$used size=$size"
truncate -s "$size" system_new.img
sudo mke2fs -q -t ext4 -b 4096 -N 20000 -m 0 -L system -O ^has_journal -d stage system_new.img
sudo e2fsck -fn system_new.img || true

sudo umount mnt_base mnt_donor
endlog

# ---------- 7. img -> dat.br ----------
log "img2sdat"
mkdir -p dat
img2simg system_new.img system_new.sparse.img
python3 img2sdat/img2sdat.py system_new.sparse.img -o dat -v 4 -p system
brotli -f -q 6 dat/system.new.dat -o dat/system.new.dat.br
ls -lh dat
endlog

# ---------- 8. собрать пакет на основе базы ----------
log "assemble package"
unzip -q -o base.zip -d pkg
cp dat/system.new.dat.br pkg/system.new.dat.br
cp dat/system.transfer.list pkg/system.transfer.list
cp dat/system.patch.dat pkg/system.patch.dat
ok "system подставлен в пакет"
endlog

# ---------- 8a. подмена прошивок из папки firmware/ ----------
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

# ---------- 8b. брендинг updater-script (баннер и мейнтейнер) ----------
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

# ---------- 8c. размеры разделов и проверка super ----------
log "dynamic partitions"
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
ok "разделы влезают в super"
endlog

# ---------- 8d. отключаем AVB-проверку во всех vbmeta ----------
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

# ---------- 9. упаковка ----------
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
  echo "| system | $(numfmt --to=iec "$newsize") |"
  echo "| zip | $(du -h "$OUT"/MIUI11-angelican-port.zip | cut -f1) |"
  echo "| sha256 | $(sha256sum "$OUT"/MIUI11-angelican-port.zip | cut -d' ' -f1) |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

ok "DONE"
