#!/bin/sh
set -eu

export PATH="$HOME/.cargo/bin:$PATH"
repo="$(cd "$SRCROOT/../.." && pwd)"
target_dir="$repo/target/macos-desktop"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$frameworks" "$resources" "$TARGET_TEMP_DIR"

cd "$repo"
set --
for arch in $ARCHS; do
  case "$arch" in
    arm64) target=aarch64-apple-darwin ;;
    x86_64) target=x86_64-apple-darwin ;;
    *) echo "Unsupported macOS architecture: $arch" >&2; exit 1 ;;
  esac
  cargo rustc --locked --lib --crate-type cdylib --release \
    --target "$target" --target-dir "$target_dir"
  set -- "$@" "$target_dir/$target/release/libtreescan.dylib"
done

pending="$TARGET_TEMP_DIR/libtreescan.dylib"
if [ "$#" -eq 1 ]; then
  cp "$1" "$pending"
else
  lipo -create "$@" -output "$pending"
fi
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$pending"
mv -f "$pending" "$frameworks/libtreescan.dylib"
cp "$repo/LICENSE" "$repo/THIRD_PARTY_NOTICES.md" "$resources/"
