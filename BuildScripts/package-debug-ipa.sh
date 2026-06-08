#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCTS_ROOT="$REPO_ROOT/Build/Products"
PRODUCTS_DIR="$PRODUCTS_ROOT/Debug-iphoneos"
PAYLOAD_DIR="$PRODUCTS_DIR/Payload"
APP_NAME="VoidLink.app"
DSYM_NAME="VoidLink.app.dSYM"
ZIP_PATH="$PRODUCTS_DIR/Payload.zip"
IPA_PATH="$PRODUCTS_DIR/Payload.ipa"
DEST_DIR="/Users/liuwei/Dropbox/Personal/Dev/builds/VoidLink IPA"
DEST_IPA="$DEST_DIR/Payload.ipa"

cd "$REPO_ROOT"

xcodebuild \
  -quiet \
  -project "$REPO_ROOT/VoidLink.xcodeproj" \
  -scheme VoidLink \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  SYMROOT="$PRODUCTS_ROOT" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$PRODUCTS_DIR/$APP_NAME"
DSYM_PATH="$PRODUCTS_DIR/$DSYM_NAME"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle: $APP_PATH" >&2
  exit 1
fi

if [[ ! -d "$DSYM_PATH" ]]; then
  echo "Missing dSYM bundle: $DSYM_PATH" >&2
  exit 1
fi

mkdir -p "$PAYLOAD_DIR" "$DEST_DIR"
rm -rf "$PAYLOAD_DIR/$APP_NAME" "$PAYLOAD_DIR/$DSYM_NAME"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"
cp -R "$DSYM_PATH" "$PAYLOAD_DIR/"

rm -f "$ZIP_PATH" "$IPA_PATH"
(
  cd "$PRODUCTS_DIR"
  zip -qry "Payload.zip" "Payload"
  mv "Payload.zip" "Payload.ipa"
)

cp -f "$IPA_PATH" "$DEST_IPA"

SIZE="$(du -h "$DEST_IPA" | awk '{print $1}')"
SHA256="$(shasum -a 256 "$DEST_IPA" | awk '{print $1}')"

echo "IPA: $DEST_IPA"
echo "Size: $SIZE"
echo "SHA256: $SHA256"
