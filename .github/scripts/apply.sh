#!/usr/bin/env bash
# ============================================================
# Redmi 9C NFC - Xiaomi.eu MIUI 11 / Android 10 PORT
#
# Layout of this port:
#   system  -> Xiaomi.eu MIUI 11 donor (product lives INSIDE system/product,
#              /product -> /system/product is kept, no product partition)
#   vendor  -> Redmi 9C stock, untouched (mounted read-only here)
#   stock system / stock product are used only as a source of MTK files
#
# Policy of this version:
#   - libraries are NOT deleted. If something needs a library that is
#     missing, it is added from the stock system when stock has it
#   - things that must not be touched are listed in KEEP_RE
#     (default: qti.hardware.data, netmgrd; more in patches/keep.txt)
#   - VINTF compatibility matrices: every <hal> becomes optional="true"
#   - build.prop / prop.default are adapted to the 9C (identity, ABI,
#     zygote, hardcoded hardware values, Qualcomm properties)
#
# IMPORTANT:
#   First-pass patch. Read the logs, they report what could not be solved.
# ============================================================

set -euo pipefail

# ---------- paths ----------

B="${BASE_ROOT:?BASE_ROOT is required}"
S="${STAGE_ROOT:?STAGE_ROOT is required}"
REPO="${REPO:?REPO is required}"

BP="${BASE_PRODUCT_ROOT:-}"
BV="${BASE_VENDOR_ROOT:-}"

# product is emulated inside system
PS=""
if [ -d "$S/product" ] && [ ! -L "$S/product" ]; then
  PS="$S/product"
fi

echo "============================================================"
echo " REDMI 9C / XIAOMI.EU MIUI 11 PORT PATCHER"
echo "============================================================"

echo "[PATH] Stock system : $B"
echo "[PATH] Donor system : $S"
echo "[PATH] Donor product: ${PS:-<нет, system/product отсутствует>} (inside system)"
echo "[PATH] Stock product: ${BP:-unavailable} (reference only, not flashed)"
echo "[PATH] Stock vendor : ${BV:-unavailable}"

for d in "$B" "$S"; do
  if [ ! -d "$d" ]; then
    echo "ERROR: required directory does not exist: $d"
    exit 1
  fi
done

# ---------- keep list ----------
# Anything matching KEEP_RE is never removed or rewritten.
# Default follows the advice "do not touch qti hardware data".

KEEP_RE='qti\.hardware\.data|netmgrd|\.data\.(connection|latency|dynamicdds|iwlan|qmi|cne)'
if [ -f "$REPO/patches/keep.txt" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    KEEP_RE="$KEEP_RE|$line"
  done < "$REPO/patches/keep.txt"
fi
export KEEP_RE
echo "[KEEP] $KEEP_RE"

# ---------- helpers ----------

section() {
  echo
  echo "============================================================"
  echo " $*"
  echo "============================================================"
}

# ---------- 1. build.prop / prop.default ----------

section "1. BUILD.PROP / PROP.DEFAULT ADAPTATION"

# - identity, ABI, zygote, board and display density are taken from stock
# - hardcoded hardware values of the donor (eMMC size, cutoff voltage,
#   board platform, abilist64) are replaced by stock values or removed
# - Qualcomm properties (qcom/qti/qualcomm/qcril/qmi, display/btstack/mm
#   prefixes) are removed, or replaced by the stock value when stock has one
# - everything matching KEEP_RE is left alone

python3 - "$B" "$S" <<'PY'
import os
import re
import sys

B, S = sys.argv[1], sys.argv[2]

keep = re.compile(os.environ.get("KEEP_RE") or r"(?!)", re.IGNORECASE)

IDENTITY = (
    "ro.product.system.device", "ro.product.system.model", "ro.product.system.name",
    "ro.product.system.brand", "ro.product.system.manufacturer",
    "ro.product.device", "ro.product.model", "ro.product.name",
    "ro.product.brand", "ro.product.manufacturer",
)

MIRROR = set(IDENTITY) | {
    "ro.build.product", "ro.product.board",
    "ro.zygote",
    "ro.product.cpu.abi", "ro.product.cpu.abilist", "ro.product.cpu.abilist32",
    "ro.sf.lcd_density",
}

DROP_UNLESS_STOCK = {
    "ro.emmc_size", "ro.cutoff_voltage_mv",
    "ro.product.cpu.abilist64", "ro.board.platform",
}

QCOM_KEY = re.compile(
    r"^(ro\.qualcomm\.|ro\.vendor\.display\.|vendor\.display\.|"
    r"persist\.vendor\.btstack\.|vendor\.mm\.)"
)
QCOM_ANY = re.compile(r"(qcom|qti|qualcomm|qcril|qmi)", re.IGNORECASE)


def parse_line(line):
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s:
        return None
    k, v = s.split("=", 1)
    return k.strip(), v.strip()


def load(path):
    d = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                kv = parse_line(line)
                if kv:
                    d[kv[0]] = kv[1]
    except OSError:
        pass
    return d


stock = {}
for rel in ("build.prop", "etc/prop.default"):
    stock.update(load(os.path.join(B, rel)))

print(f"[PROP] stock properties loaded: {len(stock)}")


def mirrored(k):
    return k in MIRROR or k.startswith("ro.hwui.")


def process(rel, add_identity):
    path = os.path.join(S, rel)
    if not os.path.isfile(path):
        print(f"[PROP] {rel}: not found, skipped")
        return

    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    out = []
    seen = set()
    changes = 0

    for line in lines:
        kv = parse_line(line)
        if not kv:
            out.append(line)
            continue

        k, v = kv
        seen.add(k)

        if keep.search(k) or keep.search(v):
            out.append(line)
            continue

        action, val = None, None

        if mirrored(k) and k in stock:
            if stock[k] != v:
                action, val = "set", stock[k]
        elif k in DROP_UNLESS_STOCK:
            if k in stock:
                if stock[k] != v:
                    action, val = "set", stock[k]
            else:
                action = "del"
        elif QCOM_KEY.search(k) or QCOM_ANY.search(k) or QCOM_ANY.search(v):
            if k in stock and not QCOM_ANY.search(stock[k]):
                if stock[k] != v:
                    action, val = "set", stock[k]
            else:
                action = "del"

        if action == "set":
            print(f"[PROP] {rel}: {k}: {v} -> {val}")
            out.append(f"{k}={val}\n")
            changes += 1
        elif action == "del":
            print(f"[PROP] {rel}: remove {k}={v}")
            changes += 1
        else:
            out.append(line)

    if add_identity:
        for k in IDENTITY:
            if k in stock and k not in seen:
                if out and not out[-1].endswith("\n"):
                    out[-1] += "\n"
                out.append(f"{k}={stock[k]}\n")
                print(f"[PROP] {rel}: add {k}={stock[k]}")
                changes += 1

    if changes:
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(out)

    print(f"[PROP] {rel}: {changes} change(s)")


process("build.prop", True)
process("etc/prop.default", False)
PY

# ---------- 2. ABI / bitness report ----------

section "2. ABI REPORT (REPORT ONLY)"

# The 9C stock userspace is expected to be 32-bit. This section shows what
# the donor looks like and which donor apps ship only arm64 native libs
# (such apps cannot run on a 32-bit-only runtime).

python3 - "$S" "$B" <<'PY'
import os
import sys

S, B = sys.argv[1], sys.argv[2]


def image_root(p):
    p = p.rstrip("/")
    return os.path.dirname(p) if os.path.basename(p) == "system" else p


def zygote_rc(root):
    try:
        return sorted(n for n in os.listdir(image_root(root)) if n.startswith("init.zygote"))
    except OSError:
        return []


def prop(root, key):
    for rel in ("etc/prop.default", "build.prop"):
        try:
            with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith(key + "="):
                        return line.strip().split("=", 1)[1]
        except OSError:
            pass
    return "<нет>"


for label, root in (("stock", B), ("donor", S)):
    has64 = "yes" if os.path.isdir(os.path.join(root, "lib64")) else "NO"
    print(
        f"[ABI] {label}: lib64={has64} zygote_rc={zygote_rc(root)} "
        f"ro.zygote={prop(root, 'ro.zygote')} abilist={prop(root, 'ro.product.cpu.abilist')} "
        f"abilist64={prop(root, 'ro.product.cpu.abilist64')}"
    )

only64 = []
with32 = 0

for sub in ("app", "priv-app", "product/app", "product/priv-app"):
    base = os.path.join(S, sub)
    if not os.path.isdir(base):
        continue
    for name in sorted(os.listdir(base)):
        ld = os.path.join(base, name, "lib")
        if not os.path.isdir(ld):
            continue
        subs = set(os.listdir(ld))
        if "arm64" in subs and "arm" not in subs:
            only64.append(f"{sub}/{name}")
        elif "arm" in subs:
            with32 += 1

print(f"[ABI] donor apps with 32-bit native libs: {with32}")
print(f"[ABI] donor apps with ONLY arm64 native libs: {len(only64)}")
for n in only64[:40]:
    print(f"[ABI ARM64-ONLY] {n}")
if len(only64) > 40:
    print(f"[ABI ARM64-ONLY] ... and {len(only64) - 40} more")

stock_32 = not os.path.isdir(os.path.join(B, "lib64"))
if stock_32 and only64:
    print(
        "::warning::stock userspace is 32-bit, donor has "
        f"{len(only64)} apps with arm64-only native libs: they will not run on a 32-bit runtime"
    )
PY

# ---------- 3. MTK framework / IMS import ----------

section "3. IMPORT MTK FRAMEWORK AND IMS FILES"

# Stock system -> donor system, stock product -> donor system/product.
# Vendor binaries are NOT copied: stock vendor is retained.

python3 - "$B" "$S" "$BP" "$PS" <<'PY'
import os
import re
import sys
import shutil

pairs = [
    (sys.argv[1], sys.argv[2], "stock-system -> donor-system"),
    (sys.argv[3], sys.argv[4], "stock-product -> donor-system/product"),
]

pattern = re.compile(r"(mediatek|mtk|ims)", re.IGNORECASE)

allowed = {
    ".apk", ".jar", ".so", ".xml", ".rc",
    ".prop", ".conf", ".cfg", ".json"
}

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
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(current, d))]

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

# ---------- 4. stock device features ----------

section "4. DEVICE FEATURES"

if [ -d "$B/etc/device_features" ]; then
  rm -rf "$S/etc/device_features"
  mkdir -p "$S/etc"
  cp -a "$B/etc/device_features" "$S/etc/device_features"
  echo "[OK] Stock device_features imported"
else
  echo "[SKIP] No stock device_features"
fi

# ---------- 5. VINTF ----------

section "5. VINTF: STOCK MATRICES, ALL HALS OPTIONAL"

# Framework compatibility matrices of the stock 9C replace the donor ones,
# then every <hal> in them gets optional="true", so a HAL that is not
# present on this device does not fail the compatibility check.
# The vendor VINTF manifest is not touched.

if [ -d "$B/etc/vintf" ]; then
  mkdir -p "$S/etc/vintf"
  shopt -s nullglob
  for f in "$B"/etc/vintf/compatibility_matrix*.xml; do
    [ -f "$f" ] || continue
    cp -a "$f" "$S/etc/vintf/"
    echo "[VINTF] Stock framework matrix imported: $(basename "$f")"
  done
  shopt -u nullglob
else
  echo "[VINTF] Stock system has no etc/vintf"
fi

python3 - "$S" <<'PY'
import glob
import os
import sys
import xml.etree.ElementTree as ET

S = sys.argv[1]

files = sorted(
    glob.glob(os.path.join(S, "etc/vintf/compatibility_matrix*.xml")) +
    glob.glob(os.path.join(S, "product/etc/vintf/compatibility_matrix*.xml"))
)

if not files:
    print("[VINTF] no compatibility matrices found")

total = 0

for path in files:
    try:
        tree = ET.parse(path)
    except Exception as e:
        print(f"[WARNING] cannot parse {path}: {e}")
        continue

    changed = 0
    for hal in tree.getroot().iter("hal"):
        if hal.get("optional") != "true":
            hal.set("optional", "true")
            changed += 1

    if changed:
        tree.write(path, encoding="utf-8", xml_declaration=True)
        total += changed

    print(f"[VINTF] {os.path.relpath(path, S)}: {changed} hal(s) set optional=true")

print(f"[VINTF] total hal entries made optional: {total}")
PY

# ---------- 6. MTK init import ----------

section "6. MTK INIT CONFIGURATION"

python3 - "$B" "$S" <<'PY'
import os
import re
import sys
import shutil

src, dst = sys.argv[1], sys.argv[2]

pattern = re.compile(r"(mediatek|mtk|ims)", re.IGNORECASE)

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

        if not rel.startswith("etc/init/") or not pattern.search(rel):
            continue

        target = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(source, target)
        print(f"[INIT COPY] {rel}")
        count += 1

print(f"[INIT RESULT] copied={count}")
PY

# ---------- 7. soft Qualcomm cleanup ----------

section "7. QUALCOMM COMPONENTS (SOFT CLEANUP, NO LIBRARIES)"

# Only applications that are useless on MediaTek are removed.
# Libraries, jars and permission files are left in place on purpose:
# removing them broke dependencies (see dependency audit in older logs).
# More paths can be added through patches/remove.txt.

DEFAULT_REMOVE=(
  "product/app/QtiSystemService"
  "product/app/QtiTelephonyService"
  "app/QTIDiagServices"
)

for p in "${DEFAULT_REMOVE[@]}"; do
  if echo "$p" | grep -Eqi "$KEEP_RE"; then
    echo "[KEEP] $p"
    continue
  fi
  if [ -e "$S/$p" ] || [ -L "$S/$p" ]; then
    rm -rf -- "${S:?}/$p"
    echo "[SOFT REMOVE] $p"
  else
    echo "[SOFT NOT FOUND] $p"
  fi
done

# ---------- 8. init cleanup ----------

section "8. QUALCOMM INIT CLEANUP"

# service / import blocks that mention Qualcomm are removed whole.
# "on" action blocks: only the offending lines are removed.
# Anything matching KEEP_RE is kept.

python3 - "$S" <<'PY'
import os
import re
import sys

S = sys.argv[1]

keep = re.compile(os.environ.get("KEEP_RE") or r"(?!)", re.IGNORECASE)

qcom = re.compile(
    r"(qualcomm|com\.qti|com\.qualcomm|vendor\.qti|vendor\.qcom|qcril|qsee|qtee|qdsp|qcom)",
    re.IGNORECASE
)


def hit(text):
    return bool(qcom.search(text)) and not keep.search(text)


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

        if kind == "action" and not hit(block[0]):
            kept = [block[0]]
            for x in block[1:]:
                s = x.strip()
                if s and not s.startswith("#") and hit(x):
                    changed = True
                    print(f"[INIT REMOVE LINE] {path}: {s}")
                else:
                    kept.append(x)
            out.extend(kept)
        elif any(hit(x) for x in block):
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


for current, dirs, files in os.walk(S):
    for name in files:
        if name.endswith(".rc"):
            clean_rc(os.path.join(current, name))
PY

# ---------- 9. remove lists ----------

section "9. REMOVE LIST (patches/remove.txt, paths relative to system)"

apply_remove_list() {
  local root="$1"
  local file="$2"
  local label="$3"

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

    if echo "$p" | grep -Eqi "$KEEP_RE"; then
      echo "[$label KEEP] $p (matches keep list)"
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

# ---------- 10. overlays ----------

section "10. OVERLAYS"

if [ -d "$REPO/patches/overlay" ]; then
  cp -a "$REPO/patches/overlay/." "$S/"
  echo "[OK] system overlay applied"
else
  echo "[SKIP] no system overlay"
fi

# ---------- 11. missing dependency resolver ----------

section "11. MISSING LIBRARY RESOLVER (ADD FROM STOCK, NOTHING IS DELETED)"

# For every ELF in the donor that needs a library which exists neither in
# donor system nor in stock vendor: if the stock system has it (same ELF
# class, 32/64 bit), copy it to the same path. Repeats until nothing new
# is added. What stock does not have is reported.

python3 - "$S" "$B" "$BV" <<'PY'
import os
import re
import shutil
import subprocess
import sys

S, B, BV = sys.argv[1:4]

if shutil.which("readelf") is None:
    print("[RESOLVE] readelf not found, skipped")
    sys.exit(0)

qcom = re.compile(
    r"(qualcomm|com\.qti|vendor\.qti|vendor\.qcom|libqti|libqcril|libqmi|qcril|qsee|qtee|qdsp|qcom)",
    re.IGNORECASE,
)


def is_lib(name):
    return name.endswith(".so") or ".so." in name


def elf_class(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(5)
        if len(head) == 5 and head[:4] == b"\x7fELF":
            return head[4]
    except OSError:
        pass
    return 0


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
    if elf_class(path):
        out = subprocess.run(
            ["readelf", "-d", path], capture_output=True, text=True
        ).stdout
        res = re.findall(r"Shared library: \[([^\]]+)\]", out)
    needs_cache[path] = res
    return res


# index of the stock system libraries: name -> [(rel, elf class)]
stock_idx = {}
for cur, dirs, files in os.walk(B):
    for n in files:
        if not is_lib(n):
            continue
        p = os.path.join(cur, n)
        if os.path.islink(p):
            continue
        cls = elf_class(p)
        if cls:
            rel = os.path.relpath(p, B).replace("\\", "/")
            stock_idx.setdefault(n, []).append((rel, cls))


def pick(name, cls):
    cands = [c for c in stock_idx.get(name, []) if c[1] == cls]
    if not cands:
        return None
    cands.sort(key=lambda c: (not c[0].startswith(("lib/", "lib64/")), len(c[0])))
    return cands[0][0]


added = []

for pass_no in range(1, 7):
    have = so_names([S, BV])
    missing = {}

    for cur, dirs, files in os.walk(S):
        for name in files:
            path = os.path.join(cur, name)
            if os.path.islink(path):
                continue
            needs = needed(path)
            if not needs:
                continue
            cls = elf_class(path)
            for n in needs:
                if n not in have:
                    missing.setdefault((n, cls), []).append(
                        os.path.relpath(path, S).replace("\\", "/")
                    )

    changed = False

    for (n, cls), users in sorted(missing.items()):
        rel = pick(n, cls)
        if not rel:
            continue
        dst = os.path.join(S, rel)
        if os.path.lexists(dst):
            continue
        src = os.path.join(B, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        st = os.stat(src)
        os.chown(dst, st.st_uid, st.st_gid)
        needs_cache.pop(dst, None)
        added.append(rel)
        print(f"[RESOLVE ADD] pass {pass_no}: {rel} <- stock (needed by {', '.join(users[:3])})")
        changed = True

    if not changed:
        break

print(f"\n[RESOLVE] libraries added from stock: {len(added)}")

# final report
have = so_names([S, BV])
final = {}
for cur, dirs, files in os.walk(S):
    for name in files:
        path = os.path.join(cur, name)
        if os.path.islink(path):
            continue
        needs = needed(path)
        if not needs:
            continue
        for n in needs:
            if n not in have:
                final.setdefault(n, []).append(os.path.relpath(path, S).replace("\\", "/"))

print(f"[RESOLVE] libraries still missing: {len(final)}")

items = sorted(final.items(), key=lambda kv: (not qcom.search(kv[0]), -len(kv[1]), kv[0]))
for n, users in items[:80]:
    tag = "MISSING QTI" if qcom.search(n) else "MISSING DEP"
    shown = ", ".join(users[:4])
    more = f" (+{len(users) - 4} more)" if len(users) > 4 else ""
    print(f"[{tag}] {n} <- {shown}{more}")
if len(items) > 80:
    print(f"[MISSING DEP] ... and {len(items) - 80} more libraries")
PY

# ---------- 12. dangling references ----------

section "12. DANGLING REFERENCES (INIT SERVICES, PERMISSION LIBRARIES)"

# init services whose binary does not exist and <library file="..."/> entries
# in permission XML whose file does not exist. Only /system and /product
# paths are checked, other locations are left alone.

python3 - "$S" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

S = sys.argv[1].rstrip("/")

root_dir = os.path.dirname(S) if os.path.basename(S) == "system" else None


def present(devpath):
    if devpath.startswith("/system/"):
        return os.path.lexists(os.path.join(S, devpath[len("/system/"):]))
    if devpath.startswith("/product/"):
        return os.path.lexists(os.path.join(S, "product", devpath[len("/product/"):]))
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

for cur, dirs, files in os.walk(S):
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

for cur, dirs, files in os.walk(S):
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

# ---------- 13. inventory ----------

section "13. HARDWARE-RELATED FILES LEFT IN SYSTEM (first 120)"

find "$S" \
  \( \
    -iname '*qcom*' -o \
    -iname '*qualcomm*' -o \
    -iname '*qti*' \
  \) \
  -print 2>/dev/null | head -120 || true

section "14. PATCH SUMMARY"

echo "Stock system : $B"
echo "Donor system : $S"
echo "Product      : inside system (no product partition)"
echo "Stock vendor : ${BV:-unavailable}"

echo
echo "Applied:"
echo "  - build.prop / prop.default: identity, ABI, zygote, hardcoded hardware values, Qualcomm properties"
echo "  - ABI report"
echo "  - MTK/IMS framework-side import from stock"
echo "  - Stock device_features"
echo "  - Stock framework compatibility matrices, all hal optional=true"
echo "  - MTK/IMS init import"
echo "  - Soft Qualcomm cleanup (apps only) and init cleanup"
echo "  - Keep list: $KEEP_RE"
echo "  - patches/remove.txt, patches/overlay"
echo "  - Missing library resolver (adds from stock, deletes nothing)"
echo "  - Dangling init services and permission library entries"

echo
echo "Not modified:"
echo "  - Stock vendor partition"
echo "  - boot.img ramdisk"
echo "  - dtbo.img"
echo "  - Stock vendor HAL binaries"

echo
echo "PATCHES DONE"
