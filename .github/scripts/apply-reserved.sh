#!/usr/bin/env bash
# Патчи для system донора. Правь этот файл по логам загрузки.
# Запускается под sudo. Переменные: BASE_ROOT (system 9C, read-only), STAGE_ROOT (копия system донора, writable), REPO.
set -euo pipefail

B="$BASE_ROOT"
S="$STAGE_ROOT"
echo "== AUDIT: топ по размеру =="
du -sm "$S"/app/* "$S"/priv-app/* "$S"/data-app/* "$S"/media "$S"/fonts 2>/dev/null | sort -n | tail -50 || true

echo "== 1. Идентичность устройства из базы 9C =="
for k in \
  ro.product.system.device ro.product.system.model ro.product.system.name \
  ro.product.system.brand ro.product.system.manufacturer \
  ro.product.device ro.product.model ro.product.name \
  ro.product.brand ro.product.manufacturer
do
  v="$(grep -m1 "^$k=" "$B/build.prop" | cut -d= -f2- || true)"
  if [ -n "$v" ] && grep -q "^$k=" "$S/build.prop"; then
    sed -i "s|^$k=.*|$k=$v|" "$S/build.prop"
    echo "  $k=$v"
  fi
done

echo "== 2. device_features и permissions от 9C =="
if [ -d "$B/etc/device_features" ]; then
  rm -rf "$S/etc/device_features"
  cp -a "$B/etc/device_features" "$S/etc/device_features"
  echo "  device_features: ok"
else
  echo "  WARN: у базы нет etc/device_features"
fi

echo "== 3. Удаление лишнего (patches/remove.txt) =="
if [ -f "$REPO/patches/remove.txt" ]; then
  while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    rm -rf "${S:?}/$p"
    echo "  rm $p"
  done < "$REPO/patches/remove.txt"
fi

echo "== 4. Оверлей поверх системы (patches/overlay/) =="
if [ -d "$REPO/patches/overlay" ]; then
  cp -a "$REPO/patches/overlay/." "$S/"
  echo "  overlay: ok"
fi

echo "patches done"
