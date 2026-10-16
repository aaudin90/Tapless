#!/usr/bin/env bash
# Сборка TapLess.app.
#   ./build_app.sh            — собрать в build/TapLess.app
#   ./build_app.sh --install  — собрать и положить в ~/Applications
#   ./build_app.sh --zip      — собрать и упаковать в build/TapLess.zip (+ .sha256) для раздачи
#
# Подпись: если в Связке ключей есть сертификат подписи кода «TapLess Dev»,
# приложение подписывается им, иначе — ad-hoc. При ad-hoc подписи macOS
# сбрасывает разрешения «Микрофон» и «Универсальный доступ» после каждой
# пересборки. Другой сертификат: SIGN_IDENTITY="Имя" ./build_app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TapLess"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
DEFAULT_IDENTITY="TapLess Dev"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$SIGN_IDENTITY"
elif security find-identity -p codesigning 2>/dev/null | grep -q "\"$DEFAULT_IDENTITY\""; then
  IDENTITY="$DEFAULT_IDENTITY"
else
  IDENTITY="-"
  echo "▸ Сертификат «$DEFAULT_IDENTITY» не найден: подпись ad-hoc, разрешения сбросятся после установки"
fi

INSTALL=0
ZIP=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --zip) ZIP=1 ;;
    *) echo "Неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done

./scripts/gen_default_config.sh

echo "▸ swift build (release, arm64)…"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "▸ Собираю $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Ресурсные бандлы зависимостей, если появятся
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

echo "▸ Подписываю ($IDENTITY)"
codesign --force --deep --sign "$IDENTITY" "$APP"

if [[ "$ZIP" == 1 ]]; then
  ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP" "$ZIP_PATH"
  (cd "$BUILD_DIR" && shasum -a 256 "$APP_NAME.zip" > "$APP_NAME.zip.sha256")
  echo "▸ Архив для раздачи: $ZIP_PATH (сумма: $ZIP_PATH.sha256)"
fi

if [[ "$INSTALL" == 1 ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x "$APP_NAME" 2>/dev/null || true
  # Ждём выхода старого процесса (до 5 с): иначе open падает с ошибкой -600.
  for _ in {1..50}; do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.1
  done
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  echo "▸ Установлено: $DEST/$APP_NAME.app"
  open "$DEST/$APP_NAME.app"
else
  echo "▸ Готово: $APP  (запуск: open $APP)"
fi
