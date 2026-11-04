
#!/usr/bin/env bash
# Stage 1 port:
# Donor: Xiaomi.eu MIUI 11 / Android 10
# Base: Redmi 9C NFC / Android 10 / MTK vendor
#
# Rebuild:
#   system only
#
# Analyze:
#   base system, base product, donor product, base vendor
#
# Stock boot/dtbo/vendor/product remain untouched in output.
# Files from firmware/ override matching files in base ZIP.

set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${DONOR_URL:?DONOR_URL is required}"

MAINT="${MAINT:-ktoya?}"

REPO="$PWD"
W="$REPO/work"
OUT="$REPO/out"

mkdir -p "$W" "$OUT"
cd "$W"

# ---------- logging ----------

C_R=$'\033[0m'
C_G=$'\033[32m'
C_B=$'\033[36m'

log()    { echo "::group::▶ $*"; }
endlog() { echo "::endgroup::"; }
ok()     { echo "${C_G}✔ $*${C_R}"; }
info()   { echo "${C_B}• $*${C_R}"; }
warn()   { echo "::warning::$*"; }

dl() {
  curl -L --fail --retry 3 --retry-delay 5 -o "$2" "$1"
}

# ---------- 1. download ----------

log "download"

dl "$BASE_URL" base.zip
dl "$DONOR_URL" donor.zip

ls -lh base.zip donor.zip
df -h /

endlog

# ---------- 2. extract archives ----------

log "unzip"

mkdir -p base donor pkg

unzip -q base.zip -d base
unzip -q donor.zip -d donor

echo "--- base:"
ls -la base

echo "--- donor:"
ls -la donor

endlog

# ---------- 3. tools ----------

log "tools"

git clone --depth 1 https://github.com/xpirt/sdat2img.git
git clone --depth 1 https://github.com/xpirt/img2sdat.git

sed -i 's/^import imp$/import importlib/' img2sdat/*.py

grep -n "imp\." img2sdat/*.py || true

command -v simg2img >/dev/null || {
  echo "ERROR: simg2img is missing. Install android-sdk-libsparse-utils."
  exit 1
}

endlog

# ---------- partition unpacking ----------

# .new.dat.br -> .new.dat -> raw ext4 image
# Direct .img is preserved as-is; sparse conversion happens before mount.

unpack() {
  local d="$1"
  local n="$2"

  if [ -f "$d/$n.new.dat.br" ]; then
    brotli -dfk "$d/$n.new.dat.br" -o "$d/$n.new.dat"
  fi

  if [ -f "$d/$n.new.dat" ]; then
    if [ ! -f "$d/$n.transfer.list" ]; then
      echo "ERROR: missing $d/$n.transfer.list"
      exit 1
    fi

    python3 sdat2img/sdat2img.py \
      "$d/$n.transfer.list" \
      "$d/$n.new.dat" \
      "$d/$n.img"

    rm -f "$d/$n.new.dat"
  fi

  if [ ! -f "$d/$n.img" ]; then
    echo "ERROR: image $n not found in $d"
    ls -la "$d"
    exit 1
  fi
}

# Optional partition unpacking
unpack_optional() {
  local d="$1"
  local n="$2"

  if [ -f "$d/$n.new.dat.br" ] || \
     [ -f "$d/$n.new.dat" ] || \
     [ -f "$d/$n.img" ]; then
    echo "[FOUND] $d/$n"
    unpack "$d" "$n"
    return 0
  fi

  echo "[SKIP] $d/$n absent"
  return 1
}

# Handle system-as-root layout
sysroot() {
  if [ -f "$1/system/build.prop" ]; then
    echo "$1/system"
  else
    echo "$1"
  fi
}

# ---------- 3a. unpack partitions ----------

log "unpack partitions (base + donor)"

# Required systems
unpack base system
unpack donor system

# Optional partitions
unpack_optional base product || true
unpack_optional donor product || true

# Stock vendor is needed for inspection only
unpack_optional base vendor || true

echo "=== BASE IMAGES ==="
find base -maxdepth 1 -type f -name '*.img' -exec ls -lh {} \;

echo "=== DONOR IMAGES ==="
find donor -maxdepth 1 -type f -name '*.img' -exec ls -lh {} \;

echo "=== IMAGE FORMATS ==="
file base/*.img donor/*.img || true

endlog

# ---------- 4. mount + stage ----------

log "mount + stage"

mkdir -p \
  mnt_base \
  mnt_donor \
  mnt_base_product \
  mnt_donor_product \
  mnt_base_vendor \
  stage \
  stage_product

mount_ro() {
  local img="$1"
  local dir="$2"

  if [ ! -f "$img" ]; then
    echo "[SKIP] image missing: $img"
    return 0
  fi

  mkdir -p "$dir"

  local kind
  kind=$(file -b "$img")

  echo "[IMAGE] $img: $kind"

  if [[ "$kind" == *"Android sparse image"* ]]; then
    local raw="${img%.img}.raw.img"

    echo "[CONVERT] sparse -> raw: $raw"

    simg2img "$img" "$raw"
    img="$raw"
  fi

  sudo mount -o loop,ro "$img" "$dir"

  echo "[MOUNTED] $img -> $dir"
}

# Stock Redmi 9C system
mount_ro base/system.img mnt_base

# Donor Xiaomi.eu system
mount_ro donor/system.img mnt_donor

# Optional stock/donor product partitions
mount_ro base/product.img mnt_base_product
mount_ro donor/product.img mnt_donor_product

# Stock Redmi 9C vendor
mount_ro base/vendor.img mnt_base_vendor

# Stage donor system
sudo rsync -aHAX mnt_donor/ stage/

# Stage donor product only if a separate image exists
if mountpoint -q mnt_donor_product; then
  sudo rsync -aHAX mnt_donor_product/ stage_product/
  echo "[STAGE] Donor product copied"
else
  echo "[INFO] No separate donor product image"
fi

BASE_ROOT="$(sysroot "$W/mnt_base")"
STAGE_ROOT="$(sysroot "$W/stage")"

echo "BASE_ROOT=$BASE_ROOT"
echo "STAGE_ROOT=$STAGE_ROOT"

echo "=== MOUNT STATUS ==="

for d in \
  mnt_base \
  mnt_donor \
  mnt_base_product \
  mnt_donor_product \
  mnt_base_vendor
do
  mountpoint "$d" || true
done

endlog

# ---------- 5. patches / audit ----------

log "patches"

echo "=== PARTITION ROOTS ==="

for d in \
  "$W/mnt_base" \
  "$W/mnt_donor" \
  "$W/mnt_base_product" \
  "$W/mnt_donor_product" \
  "$W/mnt_base_vendor" \
  "$W/stage" \
  "$W/stage_product"
do
  if mountpoint -q "$d"; then
    echo "[MOUNTED] $d"
  elif [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    echo "[DIRECTORY] $d"
  else
    echo "[EMPTY/UNAVAILABLE] $d"
  fi
done

sudo env \
  BASE_ROOT="$BASE_ROOT" \
  STAGE_ROOT="$STAGE_ROOT" \
  BASE_PRODUCT_ROOT="$W/mnt_base_product" \
  DONOR_PRODUCT_ROOT="$W/mnt_donor_product" \
  STAGE_PRODUCT_ROOT="$W/stage_product" \
  BASE_VENDOR_ROOT="$W/mnt_base_vendor" \
  REPO="$REPO" \
  bash "$REPO/.github/scripts/apply.sh"

endlog

# ---------- 6. build system image ----------

log "build system image"

used=$(sudo du -sb stage | cut -f1)

# 2% reserve + 48 MiB, aligned to 4096
size=$(( (used * 102 / 100 + 48 * 1024 * 1024) / 4096 * 4096 ))

echo "used=$used size=$size"

truncate -s "$size" system_new.img

sudo mke2fs \
  -q \
  -t ext4 \
  -b 4096 \
  -N 20000 \
  -m 0 \
  -L system \
  -O ^has_journal \
  -d stage \
  system_new.img

sudo e2fsck -fn system_new.img || true

# Unmount every inspected partition
sudo umount \
  mnt_base \
  mnt_donor \
  mnt_base_product \
  mnt_donor_product \
  mnt_base_vendor 2>/dev/null || true

endlog

# ---------- 7. img -> dat.br ----------

log "img2sdat"

mkdir -p dat

img2simg system_new.img system_new.sparse.img

python3 img2sdat/img2sdat.py \
  system_new.sparse.img \
  -o dat \
  -v 4 \
  -p system

brotli -f -q 6 \
  dat/system.new.dat \
  -o dat/system.new.dat.br

ls -lh dat

endlog

# ---------- 8. assemble package ----------

log "assemble package"

unzip -q -o base.zip -d pkg

cp dat/system.new.dat.br pkg/system.new.dat.br
cp dat/system.transfer.list pkg/system.transfer.list
cp dat/system.patch.dat pkg/system.patch.dat

ok "system replaced in base package"

endlog

# ---------- 8a. firmware overrides ----------

log "firmware overrides"

shopt -s nullglob

if [ -d "$REPO/firmware" ]; then
  for f in "$REPO"/firmware/*; do
    [ -f "$f" ] || continue

    n=$(basename "$f")

    case "$n" in
      README*|.gitkeep)
        continue
        ;;
    esac

    if [ -f "pkg/$n" ]; then
      old=$(sha256sum "pkg/$n" | cut -c1-12)
      new=$(sha256sum "$f" | cut -c1-12)

      if [ "$old" = "$new" ]; then
        info "$n: identical to stock ($old), skipped"
      else
        cp "$f" "pkg/$n"
        ok "$n: replaced ($old -> $new)"
      fi
    else
      warn "$n: not found in base package, skipped"
    fi
  done
else
  info "firmware/ directory missing; stock firmware retained"
fi

shopt -u nullglob

endlog

# ---------- 8b. updater-script branding ----------

log "updater-script branding"

US=pkg/META-INF/com/google/android/updater-script

if [ ! -f "$US" ]; then
  echo "ERROR: updater-script not found: $US"
  exit 1
fi

BANNER=""

for c in \
  "$REPO/patches/banner.txt" \
  "$REPO/.github/scripts/banner.txt"
do
  if [ -f "$c" ]; then
    BANNER="$c"
    break
  fi
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

sed -i \
  's|^ui_print("Target:.*|ui_print("MIUI 11 port, base 12.0.16.0");|' \
  "$US"

sed -i '1r banner.edify' "$US"

if [ -n "$BANNER" ]; then
  ok "banner added from $BANNER"
else
  info "banner.txt not found; using default header"
fi

echo "--- updater-script preview:"
head -n 30 "$US"

endlog

# ---------- 8c. dynamic partitions ----------

log "dynamic partitions"

newsize=$(stat -c %s system_new.img)

if [ ! -f pkg/dynamic_partitions_op_list ]; then
  echo "ERROR: dynamic_partitions_op_list not found"
  exit 1
fi

sed -i -E \
  "s/^(resize system )[0-9]+/\1${newsize}/" \
  pkg/dynamic_partitions_op_list

echo "--- dynamic_partitions_op_list:"
cat pkg/dynamic_partitions_op_list

python3 - "pkg/dynamic_partitions_op_list" <<'PY'
import re
import sys

t = open(sys.argv[1]).read()

g = re.search(r'^add_group \S+ (\d+)', t, re.M)
r = [
    int(x)
    for x in re.findall(r'^resize \S+ (\d+)', t, re.M)
]

print(
    "group max:",
    g.group(1) if g else "n/a",
    "| sum of partitions:",
    sum(r)
)

if g and sum(r) > int(g.group(1)):
    sys.exit(
        "ERROR: partitions exceed super group capacity. "
        "Reduce system size or remove files."
    )
PY

ok "partition sizes fit super group"

endlog

# ---------- 8d. AVB ----------

log "vbmeta"

shopt -s nullglob
VBMETA_FILES=(pkg/vbmeta*.img)
shopt -u nullglob

if [ "${#VBMETA_FILES[@]}" -eq 0 ]; then
  info "No vbmeta images found"
else
  python3 - "${VBMETA_FILES[@]}" <<'PY'
import sys

for p in sys.argv[1:]:
    with open(p, "rb") as f:
        b = bytearray(f.read())

    if b[:4] != b"AVB0":
        print("skip (not AVB):", p)
        continue

    if len(b) <= 123:
        print("skip (too small):", p)
        continue

    b[123] = 3

    with open(p, "wb") as f:
        f.write(b)

    print("patched:", p)
PY
fi

endlog

# ---------- 9. package ----------

log "zip"

(
  cd pkg
  zip -r -1 -q "$OUT/MIUI11-angelican-port.zip" .
)

ls -lh "$OUT"

ok "zip assembled"

endlog

# ---------- workflow summary ----------

{
  echo "## MIUI 11 port"
  echo "| parameter | value |"
  echo "|---|---|"
  echo "| system | $(numfmt --to=iec "$newsize") |"
  echo "| zip | $(du -h "$OUT"/MIUI11-angelican-port.zip | cut -f1) |"
  echo "| sha256 | $(sha256sum "$OUT"/MIUI11-angelican-port.zip | cut -d' ' -f1) |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

ok "DONE"
