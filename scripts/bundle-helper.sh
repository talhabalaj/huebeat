#!/bin/sh
# Copies the Node Zigbee helper and its dependencies into the app and signs the native serialport addon.
# Idempotent on purpose: Xcode skips re-sealing the app when nothing changed, so unchanged files must stay byte-identical.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
if [ ! -d "$root/Helper/node_modules/zigbee-herdsman" ]; then
    (cd "$root/Helper" && npm ci --omit=dev --no-audit --no-fund)
fi
helper="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Helper"
mkdir -p "$helper"
# Only macOS serialport prebuilds are useful; the rest is dead weight in the bundle.
# Addons are copied and signed separately: re-copying a signed addon would change its bytes on every build.
/usr/bin/rsync -a --delete \
    --exclude 'prebuilds/android-*' --exclude 'prebuilds/linux-*' --exclude 'prebuilds/win32-*' --exclude '*.node' \
    --include '/huebeat-zigbee.cjs' --include '/package.json' --include '/node_modules/***' --exclude '/*' \
    "$root/Helper/" "$helper/"
(cd "$root/Helper" && find node_modules -name '*.node' -type f ! -path '*/prebuilds/android-*' ! -path '*/prebuilds/linux-*' ! -path '*/prebuilds/win32-*') |
while read -r addon; do
    source="$root/Helper/$addon"
    target="$helper/$addon"
    if [ -f "$target" ] && [ "$target" -nt "$source" ] && /usr/bin/codesign --verify "$target" 2>/dev/null; then continue; fi
    mkdir -p "$(dirname "$target")"
    cp "$source" "$target"
    if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
        : "${EXPANDED_CODE_SIGN_IDENTITY:?A signing identity is required for the helper native addon}"
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$target"
    fi
done
