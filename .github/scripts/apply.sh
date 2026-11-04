#!/usr/bin/env bash
# ============================================================
# Redmi 9C NFC - Xiaomi.eu MIUI 11 / Android 10 PORT
#
# Donor:
#   system  -> Xiaomi.eu MIUI 11
#   product -> Xiaomi.eu MIUI 11 (when available)
#
# Base:
#   system  -> Redmi 9C stock
#   product -> Redmi 9C stock
#   vendor  -> Redmi 9C stock (kept unchanged)
#
# Adaptation:
#   - Device identity
#   - MTK IMS/framework files from stock
#   - Stock product VINTF
#   - Stock system compatibility matrix
#   - Conservative Qualcomm cleanup
#   - XML registration cleanup
#   - Qualcomm init service block cleanup
#   - Optional remove lists and overlays
#   - Dependency cascade: whatever needs a removed library is removed,
#     or restored from stock if it is a required component
#   - Dangling references cleanup (init services, permission libraries)
#   - ELF dependency audit (report only)
#
# IMPORTANT:
#   This is a first-pass porting patch, not a guarantee of
#   complete IMS compatibility. Review the generated logs.
# ============================================================

set -euo pipefail

# ---------- paths ----------

B="${BASE_ROOT:?BASE_ROOT is required}"
S="${STAGE_ROOT:?STAGE_ROOT is required}"
REPO="${REPO:?REPO is required}"

BP="${BASE_PRODUCT_ROOT:-}"
DP="${DONOR_PRODUCT_ROOT:-}"
PS="${STAGE_PRODUCT_ROOT:-}"
BV="${BASE_VENDOR_ROOT:-}"

# names of libraries removed by this script, used by the dependency cascade
REMOVED_LIST="$(mktemp)"
export REMOVED_LIST

echo "============================================================"
echo " REDMI 9C / XIAOMI.EU MIUI 11 PORT PATCHER"
echo "============================================================"

echo "[PATH] Stock system : $B"
echo "[PATH] Donor system : $S"
echo "[PATH] Stock product: ${BP:-unavailable}"
echo "[PATH] Donor product: ${DP:-unavailable}"
echo "[PATH] Stage product: ${PS:-unavailable}"
echo "[PATH] Stock vendor : ${BV:-unavailable}"

for d in "$B" "$S"; do
  if [ ! -d "$d" ]; then
    echo "ERROR: required directory does not exist: $d"
    exit 1
  fi
done

mkdir -p "$S"

if [ -n "$PS" ]; then
  mkdir -p "$PS"
fi

# ---------- helpers ----------

section() {
  echo
  echo "============================================================"
  echo " $*"
  echo "============================================================"
}

available() {
  [ -n "${1:-}" ] && [ -d "$1" ] && \
    [ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

# ---------- 1. device identity ----------

section "1. DEVICE IDENTITY"

IDENTITY_KEYS=(
  ro.product.system.device
  ro.product.system.model
  ro.product.system.name
  ro.product.system.brand
  ro.product.system.manufacturer
  ro.product.device
  ro.product.model
  ro.product.name
  ro.product.brand
  ro.product.manufacturer
)

for k in "${IDENTITY_KEYS[@]}"; do
  v="$(grep -m1 "^${k}=" "$B/build.prop" 2>/dev/null | cut -d= -f2- || true)"

  [ -n "$v" ] || continue

  if grep -q "^${k}=" "$S/build.prop"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$S/build.prop"
  else
    printf '%s=%s\n' "$k" "$v" >> "$S/build.prop"
  fi

  echo "[IDENTITY] $k=$v"
done

# ---------- 2. MTK framework / IMS import ----------

section "2. IMPORT MTK FRAMEWORK AND IMS FILES"

# Copy only framework-side files from stock system/product.
# Vendor binaries are NOT copied: stock vendor is retained.
#
# This intentionally does not copy every file containing "radio"
# or "telephony". Only explicit MTK/MediaTek/IMS paths are selected.

python3 - "$B" "$S" "$BP" "$PS" <<'PY'
import os
import re
import sys
import shutil

pairs = [
    (sys.argv[1], sys.argv[2], "stock-system -> donor-system"),
    (sys.argv[3], sys.argv[4], "stock-product -> donor-product"),
]

pattern = re.compile(
    r"(mediatek|mtk|ims)",
    re.IGNORECASE
)

allowed = {
    ".apk", ".jar", ".so", ".xml", ".rc",
    ".prop", ".conf", ".cfg", ".json"
}

# Only import files from framework/configuration locations.
allowed_roots = (
    "app/",
    "priv-app/",
    "framework/",
    "etc/permissions/",
    "etc/sysconfig/",
    "etc/init/",
    "etc/vintf/",
    "etc/selinux/",
    "lib/",
    "lib64/",
    "overlay/",
    "product/app/",
    "product/priv-app/",
    "product/framework/",
    "product/etc/",
    "product/lib/",
    "product/lib64/",
)

for src, dst, label in pairs:
    print(f"\n[MTK IMPORT] {label}")

    if not src or not dst or not os.path.isdir(src) or not os.path.isdir(dst):
        print("[SKIP] source or destination unavailable")
        continue

    copied = 0

    for current, dirs, files in os.walk(src):
        dirs[:] = [
            d for d in dirs
            if not os.path.islink(os.path.join(current, d))
        ]

        for filename in files:
            source = os.path.join(current, filename)

            if os.path.islink(source):
                continue

            rel = os.path.relpath(source, src).replace("\\", "/")
            ext = os.path.splitext(filename)[1].lower()

            if ext not in allowed:
                continue

            if not any(rel.startswith(prefix) for prefix in allowed_roots):
                continue

            if not pattern.search(rel):
                continue

            target = os.path.join(dst, rel)

            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(source, target)

            print(f"[MTK COPY] {rel}")
            copied += 1

    print(f"[MTK RESULT] copied={copied}")
PY

# ---------- 3. stock device features ----------

section "3. DEVICE FEATURES"

if [ -d "$B/etc/device_features" ]; then
  rm -rf "$S/etc/device_features"
  mkdir -p "$S/etc"

  cp -a "$B/etc/device_features" "$S/etc/device_features"

  echo "[OK] Stock device_features imported"
else
  echo "[SKIP] No stock device_features"
fi

# ---------- 4. stock VINTF compatibility ----------

section "4. VINTF ADAPTATION"

# Framework compatibility matrices describe what the framework
# expects from vendor. Stock 9C matrix is a better starting point
# for the retained stock MTK vendor than the donor's Qualcomm matrix.
#
# Do not replace the complete system/etc/vintf directory:
# donor framework manifest and unrelated MIUI configuration stay.

if [ -d "$B/etc/vintf" ]; then
  mkdir -p "$S/etc/vintf"

  shopt -s nullglob

  MATRIX_FILES=(
    "$B"/etc/vintf/compatibility_matrix*.xml
  )

  if [ "${#MATRIX_FILES[@]}" -gt 0 ]; then
    for f in "${MATRIX_FILES[@]}"; do
      [ -f "$f" ] || continue
      cp -a "$f" "$S/etc/vintf/"
      echo "[VINTF] Stock framework matrix imported: $(basename "$f")"
    done
  else
    echo "[VINTF] No stock system compatibility matrix found"
  fi

  shopt -u nullglob
else
  echo "[VINTF] Stock system has no etc/vintf"
fi

# Product VINTF is device/product-specific.
# If stock product exists, replace donor product VINTF with stock
# product VINTF. This does not touch vendor VINTF.

if available "$BP" && available "$PS"; then
  if [ -d "$BP/etc/vintf" ]; then
    rm -rf "$PS/etc/vintf"
    mkdir -p "$PS/etc"
    cp -a "$BP/etc/vintf" "$PS/etc/vintf"
    echo "[VINTF] Stock product VINTF imported"
  else
    echo "[VINTF] Stock product has no etc/vintf"
  fi
else
  echo "[VINTF] Product VINTF import skipped: product unavailable"
fi

# ---------- 5. stock device init configuration ----------

section "5. MTK INIT CONFIGURATION"

# Import only explicitly MTK/IMS-related init files.
# Do not copy all stock init scripts over donor platform init.

python3 - "$B" "$S" "$BP" "$PS" <<'PY'
import os
import re
import sys
import shutil

pairs = [
    (sys.argv[1], sys.argv[2], "system"),
    (sys.argv[3], sys.argv[4], "product"),
]

pattern = re.compile(r"(mediatek|mtk|ims)", re.IGNORECASE)

for src, dst, label in pairs:
    print(f"\n[INIT IMPORT] {label}")

    if not src or not dst or not os.path.isdir(src) or not os.path.isdir(dst):
        print("[SKIP] unavailable")
        continue

    count = 0

    for current, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(current, d))]

        for name in files:
            if not name.endswith(".rc"):
                continue

            source = os.path.join(current, name)
            if os.path.islink(source):
                continue

            rel = os.path.relpath(source, src).replace("\\", "/")

            if not rel.startswith("etc/init/"):
                continue

            if not pattern.search(rel):
                continue

            target = os.path.join(dst, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(source, target)

            print(f"[INIT COPY] {rel}")
            count += 1

    print(f"[INIT RESULT] copied={count}")
PY

# ---------- 6. conservative Qualcomm cleanup ----------

section "6. QUALCOMM COMPONENT CLEANUP"

# Deliberately conservative:
#
# Removed:
#   - clearly Qualcomm-named files/directories
#   - QTI / Qualcomm packages and libraries
#   - Qualcomm-specific init scripts
#
# Preserved:
#   - generic IMS/RIL/radio libraries
#   - generic Android telephony framework
#   - files without clear Qualcomm identification
#   - stock vendor partition
#
# Names of removed libraries are written to $REMOVED_LIST,
# the dependency cascade (section 12b) uses them.

python3 - "$S" "$PS" <<'PY'
import os
import re
import sys
import shutil

roots = [
    ("donor-system", sys.argv[1]),
    ("donor-product", sys.argv[2]),
]

qcom = re.compile(
    r"("
    r"qualcomm|"
    r"com\.qualcomm|"
    r"com\.qti|"
    r"vendor\.qti|"
    r"vendor\.qcom|"
    r"libqti|"
    r"libqcril|"
    r"libqmi|"
    r"qcril|"
    r"qsee|"
    r"qtee|"
    r"qdsp|"
    r"qcom"
    r")",
    re.IGNORECASE
)

removed_names = []


def is_lib(name):
    return name.endswith(".so") or ".so." in name


def record_dir_libs(path):
    for cur, dirs, files in os.walk(path):
        for n in files:
            if is_lib(n):
                removed_names.append(n)


for label, root in roots:
    print(f"\n[QCOM CLEAN] {label}")

    if not root or not os.path.isdir(root):
        print("[SKIP] unavailable")
        continue

    removed = 0

    for current, dirs, files in os.walk(root, topdown=True):
        rel_current = os.path.relpath(current, root).replace("\\", "/")

        kept_dirs = []

        for d in dirs:
            path = os.path.join(current, d)
            rel = os.path.join(rel_current, d).replace("\\", "/")

            if qcom.search(rel):
                print(f"[QCOM REMOVE DIR] {rel}")
                record_dir_libs(path)
                shutil.rmtree(path, ignore_errors=True)
                removed += 1
            else:
                kept_dirs.append(d)

        dirs[:] = kept_dirs

        for name in files:
            path = os.path.join(current, name)
            rel = os.path.relpath(path, root).replace("\\", "/")

            if qcom.search(rel):
                try:
                    os.remove(path)
                    print(f"[QCOM REMOVE FILE] {rel}")
                    removed += 1
                    if is_lib(name):
                        removed_names.append(name)
                except OSError as e:
                    print(f"[WARNING] cannot remove {rel}: {e}")

    print(f"[QCOM RESULT] removed={removed}")

lst = os.environ.get("REMOVED_LIST")
if lst:
    with open(lst, "a", encoding="utf-8") as f:
        for n in sorted(set(removed_names)):
            f.write(n + "\n")
    print(f"\n[QCOM] removed library names recorded: {len(set(removed_names))}")
PY

# ---------- 7. remove Qualcomm init service blocks ----------

section "7. QUALCOMM INIT SERVICE CLEANUP"

# service / import blocks that mention Qualcomm are removed whole.
# "on" action blocks: only the offending lines are removed, so other
# commands in the same block are kept (unless the trigger itself is Qualcomm).

python3 - "$S" "$PS" <<'PY'
import os
import re
import sys

roots = [
    ("donor-system", sys.argv[1]),
    ("donor-product", sys.argv[2]),
]

qcom = re.compile(
    r"(qualcomm|com\.qti|com\.qualcomm|vendor\.qti|vendor\.qcom|qcril|qsee|qtee|qdsp|qcom)",
    re.IGNORECASE
)

HEADERS = ("service ", "on ", "import ")


def clean_rc(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return

    out = []
    block = []
    kind = None
    changed = False

    def flush():
        nonlocal block, kind, changed
        if not block:
            return

        if kind == "action" and not qcom.search(block[0]):
            kept = [block[0]]
            for x in block[1:]:
                s = x.strip()
                if s and not s.startswith("#") and qcom.search(x):
                    changed = True
                    print(f"[INIT REMOVE LINE] {path}: {s}")
                else:
                    kept.append(x)
            out.extend(kept)
        elif any(qcom.search(x) for x in block):
            changed = True
            print(f"[INIT REMOVE {kind.upper()}] {path}: {block[0].strip()}")
        else:
            out.extend(block)

        block = []
        kind = None

    for line in lines:
        stripped = line.strip()

        if stripped.startswith(HEADERS):
            flush()
            block = [line]
            if stripped.startswith("service "):
                kind = "service"
            elif stripped.startswith("on "):
                kind = "action"
            else:
                kind = "import"
        elif block and (line[:1].isspace() or not stripped or stripped.startswith("#")):
            block.append(line)
        else:
            flush()
            out.append(line)

    flush()

    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(out)


for label, root in roots:
    print(f"\n[INIT CLEAN] {label}")

    if not root or not os.path.isdir(root):
        print("[SKIP] unavailable")
        continue

    for current, dirs, files in os.walk(root):
        for name in files:
            if name.endswith(".rc"):
                clean_rc(os.path.join(current, name))
PY

# ---------- 8. XML registration cleanup ----------

section "8. XML REGISTRATION CLEANUP"

# Remove Qualcomm-specific XML nodes, especially:
#   - VINTF HAL declarations
#   - shared library registrations
#   - Qualcomm permissions/features
#
# Generic IMS entries are preserved unless their actual XML node
# explicitly references Qualcomm/QTI.

python3 - "$S" "$PS" <<'PY'
import os
import re
import sys
import xml.etree.ElementTree as ET

roots = [
    ("donor-system", sys.argv[1]),
    ("donor-product", sys.argv[2]),
]

qcom = re.compile(
    r"(qualcomm|com\.qti|com\.qualcomm|vendor\.qti|vendor\.qcom|libqti|libqcril|qcril|qsee|qtee|qdsp|qcom)",
    re.IGNORECASE
)

removable_tags = {
    "hal",
    "library",
    "feature",
    "permission",
    "assign-permission",
    "privapp-permissions",
    "uses-library",
    "interface",
}

for label, root in roots:
    print(f"\n[XML CLEAN] {label}")

    if not root or not os.path.isdir(root):
        print("[SKIP] unavailable")
        continue

    for current, dirs, files in os.walk(root):
        for name in files:
            if not name.endswith(".xml"):
                continue

            path = os.path.join(current, name)

            try:
                tree = ET.parse(path)
                document = tree.getroot()
            except Exception:
                continue

            parents = {
                child: parent
                for parent in document.iter()
                for child in parent
            }

            removed = 0

            for node in reversed(list(document.iter())):
                parent = parents.get(node)
                if parent is None:
                    continue

                tag = node.tag.split("}")[-1]

                if tag not in removable_tags:
                    continue

                content = " ".join(
                    [str(x) for x in node.attrib.values()] +
                    [node.text or ""] +
                    [
                        child.text or ""
                        for child in node.iter()
                        if child is not node
                    ]
                )

                if qcom.search(content):
                    parent.remove(node)
                    removed += 1

            if removed:
                try:
                    tree.write(
                        path,
                        encoding="utf-8",
                        xml_declaration=True
                    )
                    print(f"[XML PRUNED] {path}: {removed} nodes")
                except Exception as e:
                    print(f"[WARNING] XML write failed: {path}: {e}")
PY

# ---------- 9. public library registration cleanup ----------

section "9. LINKER PUBLIC LIBRARY REGISTRATIONS"

# Remove explicit Qualcomm lines from public library lists.
# Do not rewrite generic linker configuration files.

python3 - "$S" "$PS" <<'PY'
import os
import re
import sys

roots = [sys.argv[1], sys.argv[2]]

qcom = re.compile(
    r"(qualcomm|com\.qti|com\.qualcomm|vendor\.qti|vendor\.qcom|libqti|libqcril|qcril|qcom)",
    re.IGNORECASE
)

for root in roots:
    if not root or not os.path.isdir(root):
        continue

    for current, dirs, files in os.walk(root):
        for name in files:
            if not name.startswith("public.libraries"):
                continue

            path = os.path.join(current, name)

            try:
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    lines = f.readlines()
            except OSError:
                continue

            kept = [line for line in lines if not qcom.search(line)]

            if len(kept) != len(lines):
                with open(path, "w", encoding="utf-8") as f:
                    f.writelines(kept)

                print(
                    f"[LINKER REGISTRATION] {path}: "
                    f"removed {len(lines) - len(kept)} entries"
                )
PY

# ---------- 10. fstab ----------

section "10. FSTAB"

# fstab is commonly located in the boot ramdisk on Android.
# This patcher does NOT unpack or modify boot.img.
#
# If stock system/product contains fstab files, copy them into
# the corresponding donor partition locations for inspection/use.

python3 - "$B" "$S" "$BP" "$PS" <<'PY'
import os
import sys
import shutil

pairs = [
    (sys.argv[1], sys.argv[2], "system"),
    (sys.argv[3], sys.argv[4], "product"),
]

for src, dst, label in pairs:
    print(f"\n[FSTAB] {label}")

    if not src or not dst or not os.path.isdir(src) or not os.path.isdir(dst):
        print("[SKIP] unavailable")
        continue

    count = 0

    for current, dirs, files in os.walk(src):
        for name in files:
            lower = name.lower()

            if not (lower.startswith("fstab") or "fstab" in lower):
                continue

            source = os.path.join(current, name)
            if os.path.islink(source):
                continue

            rel = os.path.relpath(source, src)
            target = os.path.join(dst, rel)

            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(source, target)

            print(f"[FSTAB COPY] {rel}")
            count += 1

    print(f"[FSTAB RESULT] copied={count}")
PY

# ---------- 11. remove lists ----------

section "11. REMOVE LISTS"

apply_remove_list() {
  local root="$1"
  local file="$2"
  local label="$3"

  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "[SKIP] $label root unavailable"
    return
  fi

  if [ ! -f "$file" ]; then
    echo "[SKIP] $file not found"
    return
  fi

  while IFS= read -r p || [ -n "$p" ]; do
    p="${p%$'\r'}"

    case "$p" in
      ''|'#'*)
        continue
        ;;
    esac

    if [[ "$p" = /* ]] || [[ "$p" == *".."* ]]; then
      echo "[BLOCKED] unsafe path: $p"
      continue
    fi

    target="$root/$p"

    if [ -e "$target" ] || [ -L "$target" ]; then
      rm -rf -- "$target"
      echo "[$label REMOVE] $p"
    else
      echo "[$label NOT FOUND] $p"
    fi
  done < "$file"
}

apply_remove_list "$S" "$REPO/patches/remove.txt" "SYSTEM"
apply_remove_list "$PS" "$REPO/patches/product-remove.txt" "PRODUCT"

# ---------- 12. overlays ----------

section "12. OVERLAYS"

if [ -d "$REPO/patches/overlay" ]; then
  cp -a "$REPO/patches/overlay/." "$S/"
  echo "[OK] system overlay applied"
else
  echo "[SKIP] no system overlay"
fi

if [ -n "$PS" ] && [ -d "$REPO/patches/product-overlay" ]; then
  mkdir -p "$PS"
  cp -a "$REPO/patches/product-overlay/." "$PS/"
  echo "[OK] product overlay applied"
else
  echo "[SKIP] no product overlay"
fi

# ---------- 12b. dependency cascade ----------

section "12b. DEPENDENCY CASCADE"

# For every ELF that still needs a library that was removed (or has a
# Qualcomm name and does not exist anywhere):
#   - optional Qualcomm/IMS-only component  -> removed, then its own
#     dependents are checked in the next pass
#   - required component (for example bin/keystore) -> replaced with the
#     stock 9C file, if stock has it
#   - otherwise -> reported as UNRESOLVED, nothing is deleted

python3 - "$S" "$B" "$PS" "$BP" "$BV" "$REMOVED_LIST" <<'PY'
import os
import re
import shutil
import subprocess
import sys

S, B, PS, BP, BV, LIST = sys.argv[1:7]

if shutil.which("readelf") is None:
    print("[CASCADE] readelf not found, skipped")
    sys.exit(0)

qcom = re.compile(
    r"(qualcomm|com\.qti|vendor\.qti|vendor\.qcom|libqti|libqcril|libqmi|qcril|qsee|qtee|qdsp|qcom)",
    re.IGNORECASE,
)

# components that may be deleted when they lose a dependency
OPTIONAL = re.compile(
    r"(qti|qcom|qualcomm|sigma|miracast|lib-ims|imsrtp|imscm|imsvt|imssettings|"
    r"imscamera|imsmedia|secureui|uceservice|uceshim|rcsconfig|wigig|cne|dpm|"
    r"embms|uimservice|uimremote|soter|wifikeystore|tui_comm)",
    re.IGNORECASE,
)

stage_roots = [(r, b) for r, b in ((S, B), (PS, BP)) if r and os.path.isdir(r)]


def is_lib(name):
    return name.endswith(".so") or ".so." in name


def so_names(roots):
    names = set()
    for root in roots:
        if root and os.path.isdir(root):
            for cur, dirs, files in os.walk(root):
                for n in files:
                    if is_lib(n):
                        names.add(n)
    return names


needs_cache = {}


def needed(path):
    if path in needs_cache:
        return needs_cache[path]
    res = None
    try:
        with open(path, "rb") as fh:
            if fh.read(4) == b"\x7fELF":
                out = subprocess.run(
                    ["readelf", "-d", path], capture_output=True, text=True
                ).stdout
                res = re.findall(r"Shared library: \[([^\]]+)\]", out)
    except OSError:
        pass
    needs_cache[path] = res
    return res


removed = set()
if LIST and os.path.isfile(LIST):
    with open(LIST, encoding="utf-8") as f:
        removed.update(x.strip() for x in f if x.strip())

print(f"[CASCADE] start: {len(removed)} removed library names known")

restored = set()
unresolved = {}
deleted = 0

for pass_no in range(1, 9):
    have = so_names([S, PS, BV])
    hits = []

    for root, base in stage_roots:
        for cur, dirs, files in os.walk(root):
            for name in files:
                path = os.path.join(cur, name)
                if os.path.islink(path):
                    continue
                needs = needed(path)
                if not needs:
                    continue
                bad = [
                    n for n in needs
                    if n not in have and (n in removed or qcom.search(n))
                ]
                if bad:
                    hits.append((root, base, path, bad))

    changed = False

    for root, base, path, bad in hits:
        rel = os.path.relpath(path, root).replace("\\", "/")
        key = (root, rel)
        name = os.path.basename(path)
        stock = os.path.join(base, rel)

        if OPTIONAL.search(rel):
            try:
                os.remove(path)
            except OSError as e:
                print(f"[WARNING] cannot remove {rel}: {e}")
                continue
            needs_cache.pop(path, None)
            print(f"[CASCADE REMOVE] pass {pass_no}: {rel} (needs {', '.join(bad)})")
            if is_lib(name):
                removed.add(name)
            unresolved.pop(key, None)
            deleted += 1
            changed = True

        elif key not in restored and os.path.isfile(stock) and not os.path.islink(stock):
            shutil.copy2(stock, path)
            st = os.stat(stock)
            os.chown(path, st.st_uid, st.st_gid)
            needs_cache.pop(path, None)
            restored.add(key)
            print(
                f"[CASCADE RESTORE] pass {pass_no}: {rel} <- stock "
                f"(donor file needed {', '.join(bad)})"
            )
            changed = True

        else:
            if key not in unresolved:
                print(f"[CASCADE UNRESOLVED] {rel} needs {', '.join(bad)}")
            unresolved[key] = bad

    if not changed:
        break

print(f"\n[CASCADE] done: removed={deleted} restored={len(restored)} unresolved={len(unresolved)}")

for (root, rel), bad in sorted(unresolved.items(), key=lambda x: x[0][1]):
    print(f"::warning::cascade unresolved: {rel} needs {', '.join(bad)}")
PY

# ---------- 12c. dangling references ----------

section "12c. DANGLING REFERENCES (INIT SERVICES, PERMISSION LIBRARIES)"

# init services whose binary no longer exists, and <library file="..."/>
# entries in permission XML whose file no longer exists.
# Only /system and /product paths are checked, other locations are left alone.

python3 - "$S" "$PS" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

S = sys.argv[1].rstrip("/")
PS = sys.argv[2].rstrip("/") if sys.argv[2] else ""

root_dir = os.path.dirname(S) if os.path.basename(S) == "system" else None


def present(devpath):
    if devpath.startswith("/system/"):
        return os.path.lexists(os.path.join(S, devpath[len("/system/"):]))
    if devpath.startswith("/product/"):
        rel = devpath[len("/product/"):]
        if PS and os.path.lexists(os.path.join(PS, rel)):
            return True
        return os.path.lexists(os.path.join(S, "product", rel))
    return True


HEADERS = ("service ", "on ", "import ")


def clean_rc(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return 0

    out = []
    block = []
    kind = None
    dropped = 0

    def flush():
        nonlocal block, kind, dropped
        if block:
            if kind == "service":
                tokens = block[0].split()
                exe = tokens[2] if len(tokens) > 2 else ""
                if exe.startswith("/") and not present(exe):
                    dropped += 1
                    print(f"[DANGLING SERVICE] {path}: {block[0].strip()}")
                    block = []
                    kind = None
                    return
            out.extend(block)
        block = []
        kind = None

    for line in lines:
        stripped = line.strip()
        if stripped.startswith(HEADERS):
            flush()
            block = [line]
            if stripped.startswith("service "):
                kind = "service"
            elif stripped.startswith("on "):
                kind = "action"
            else:
                kind = "import"
        elif block and (line[:1].isspace() or not stripped or stripped.startswith("#")):
            block.append(line)
        else:
            flush()
            out.append(line)
    flush()

    if dropped:
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(out)
    return dropped


total_services = 0

scan_roots = [S] + ([PS] if PS else [])
for root in scan_roots:
    if not os.path.isdir(root):
        continue
    for cur, dirs, files in os.walk(root):
        for name in files:
            if name.endswith(".rc"):
                total_services += clean_rc(os.path.join(cur, name))

if root_dir and os.path.isdir(root_dir):
    for name in os.listdir(root_dir):
        p = os.path.join(root_dir, name)
        if name.startswith("init") and name.endswith(".rc") and os.path.isfile(p) and not os.path.islink(p):
            total_services += clean_rc(p)

print(f"[DANGLING] init services removed: {total_services}")

total_libs = 0

for root in scan_roots:
    if not os.path.isdir(root):
        continue
    for cur, dirs, files in os.walk(root):
        if os.path.basename(cur) != "permissions":
            continue
        for name in files:
            if not name.endswith(".xml"):
                continue
            path = os.path.join(cur, name)
            try:
                tree = ET.parse(path)
                document = tree.getroot()
            except Exception:
                continue

            parents = {c: p for p in document.iter() for c in p}
            removed = 0

            for node in list(document.iter()):
                if node.tag.split("}")[-1] != "library":
                    continue
                f = node.attrib.get("file", "")
                if f.startswith(("/system/", "/product/")) and not present(f):
                    parent = parents.get(node)
                    if parent is not None:
                        parent.remove(node)
                        removed += 1
                        print(f"[DANGLING LIBRARY] {path}: {f}")

            if removed:
                try:
                    tree.write(path, encoding="utf-8", xml_declaration=True)
                    total_libs += removed
                except Exception as e:
                    print(f"[WARNING] XML write failed: {path}: {e}")

print(f"[DANGLING] permission library entries removed: {total_libs}")
PY

# ---------- 12d. ELF dependency audit (report only) ----------

section "12d. ELF DEPENDENCY AUDIT"

# Final report, nothing is changed here.
#   [BROKEN DEP]  needed library has a Qualcomm name and is missing
#   [MISSING DEP] any other needed library that is not found in
#                 donor system/product or stock vendor (first 40 shown)
# A missing DT_NEEDED library can stop a native service or system_server.

python3 - "$S" "$PS" "$BV" <<'PY'
import os
import re
import shutil
import subprocess
import sys

if shutil.which("readelf") is None:
    print("[ELF AUDIT] readelf not found, audit skipped")
    sys.exit(0)

qcom = re.compile(
    r"(qualcomm|com\.qti|vendor\.qti|vendor\.qcom|libqti|libqcril|libqmi|qcril|qsee|qtee|qdsp|qcom)",
    re.IGNORECASE
)

stage_roots = [r for r in sys.argv[1:3] if r and os.path.isdir(r)]
have_roots = [r for r in sys.argv[1:4] if r and os.path.isdir(r)]

have = set()
for root in have_roots:
    for current, dirs, files in os.walk(root):
        for name in files:
            if name.endswith(".so") or ".so." in name:
                have.add(name)

broken = {}
other = {}

for root in stage_roots:
    for current, dirs, files in os.walk(root):
        for name in files:
            path = os.path.join(current, name)

            if os.path.islink(path):
                continue

            try:
                with open(path, "rb") as fh:
                    if fh.read(4) != b"\x7fELF":
                        continue
            except OSError:
                continue

            out = subprocess.run(
                ["readelf", "-d", path],
                capture_output=True,
                text=True
            ).stdout

            for m in re.finditer(r"Shared library: \[([^\]]+)\]", out):
                need = m.group(1)
                if need in have:
                    continue
                rel = os.path.relpath(path, root).replace("\\", "/")
                if qcom.search(need):
                    broken.setdefault(need, []).append(rel)
                else:
                    other.setdefault(need, []).append(rel)


def show(tag, table, limit):
    items = sorted(table.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    for need, users in items[:limit]:
        shown = ", ".join(users[:4])
        more = f" (+{len(users) - 4} more)" if len(users) > 4 else ""
        print(f"[{tag}] {need} <- {shown}{more}")
    if len(items) > limit:
        print(f"[{tag}] ... and {len(items) - limit} more libraries")


print(f"[ELF AUDIT] missing Qualcomm libraries still referenced: {len(broken)}")
show("BROKEN DEP", broken, 200)

print(f"[ELF AUDIT] other missing libraries: {len(other)}")
show("MISSING DEP", other, 40)

if not broken:
    print("[ELF AUDIT] OK: no broken Qualcomm dependencies found")
PY

# ---------- 13. final inventory ----------

section "13. FINAL INVENTORY"

for pair in \
  "SYSTEM:$S" \
  "PRODUCT:$PS"
do
  label="${pair%%:*}"
  root="${pair#*:}"

  [ -n "$root" ] && [ -d "$root" ] || continue

  echo
  echo "--- $label hardware-related files ---"

  find "$root" \
    \( \
      -iname '*mtk*' -o \
      -iname '*mediatek*' -o \
      -iname '*ims*' -o \
      -iname '*ril*' -o \
      -iname '*qcom*' -o \
      -iname '*qualcomm*' -o \
      -iname '*qti*' \
    \) \
    -print 2>/dev/null | head -300 || true
done

section "14. PATCH SUMMARY"

echo "Stock system : $B"
echo "Donor system : $S"
echo "Stock product: ${BP:-unavailable}"
echo "Donor product: ${DP:-unavailable}"
echo "Stage product: ${PS:-unavailable}"
echo "Stock vendor : ${BV:-unavailable}"

echo
echo "Applied:"
echo "  - Device identity"
echo "  - MTK/IMS framework-side import"
echo "  - Stock device_features"
echo "  - Stock framework compatibility matrices"
echo "  - Stock product VINTF when available"
echo "  - MTK/IMS init import"
echo "  - Conservative Qualcomm cleanup"
echo "  - Qualcomm init cleanup (services whole, action blocks by line)"
echo "  - Qualcomm XML registration cleanup"
echo "  - Qualcomm public library registration cleanup"
echo "  - Stock fstab files copied when present"
echo "  - remove.txt / product-remove.txt"
echo "  - system/product overlays"
echo "  - Dependency cascade (remove optional dependents, restore required ones)"
echo "  - Dangling init services and permission library entries removed"
echo "  - ELF dependency audit (report only)"

echo
echo "Not modified:"
echo "  - Stock vendor partition"
echo "  - boot.img ramdisk"
echo "  - dtbo.img"
echo "  - Stock vendor HAL binaries"

echo
echo "PATCHES DONE"
