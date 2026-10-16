#!/usr/bin/env bash
# Установка TapLess из GitHub Releases одной командой:
#   curl -fsSL https://raw.githubusercontent.com/aaudin90/Tapless/main/scripts/install.sh | bash
#
# Переменные окружения:
#   TAPLESS_VERSION      — тег релиза (например v0.1.0); по умолчанию последний релиз
#   TAPLESS_INSTALL_DIR  — папка установки; по умолчанию ~/Applications
#   TAPLESS_NO_LAUNCH=1  — не запускать приложение после установки
#   TAPLESS_SKIP_QUIT=1  — служебная: не закрывать запущенный TapLess (для проверок)
set -euo pipefail

REPO="aaudin90/Tapless"
APP_NAME="TapLess"
BUNDLE_ID="io.github.aaudin90.tapless"
ASSET="$APP_NAME.zip"
TMP_DIR=""

fail() {
  echo "✗ $*" >&2
  exit 1
}

step() {
  echo "▸ $*"
}

# Сверяет SHA-256 файла с файлом суммы в формате `shasum -a 256` (первое поле — хэш).
verify_checksum() {
  local file="$1" sum_file="$2" expected actual
  expected="$(awk 'NR == 1 { print tolower($1) }' "$sum_file")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "Файл контрольной суммы повреждён: ожидался SHA-256 в первом поле"
  actual="$(shasum -a 256 "$file" | awk '{ print $1 }')"
  if [[ "$actual" != "$expected" ]]; then
    fail "Контрольная сумма не совпала (ожидалась $expected, получена $actual). Установка отменена"
  fi
}

# Закрывает запущенный TapLess: сначала корректно, через 5 с — принудительно.
quit_running_app() {
  pgrep -x "$APP_NAME" >/dev/null || return 0
  step "Закрываю запущенный $APP_NAME"
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
  local _
  for _ in {1..50}; do
    pgrep -x "$APP_NAME" >/dev/null || return 0
    sleep 0.1
  done
  pkill -x "$APP_NAME" 2>/dev/null || true
  for _ in {1..50}; do
    pgrep -x "$APP_NAME" >/dev/null || return 0
    sleep 0.1
  done
  fail "Не удалось закрыть $APP_NAME. Закройте его вручную и повторите установку"
}

main() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "TapLess работает только на macOS"
  [[ "$(uname -m)" == "arm64" ]] || fail "Нужен Mac на Apple Silicon (arm64), а здесь $(uname -m)"
  local os_major
  os_major="$(sw_vers -productVersion | cut -d. -f1)"
  [[ "$os_major" =~ ^[0-9]+$ && "$os_major" -ge 14 ]] || fail "Нужна macOS 14 или новее, а здесь $(sw_vers -productVersion)"

  local base_url tag_label
  if [[ -n "${TAPLESS_VERSION:-}" ]]; then
    base_url="https://github.com/$REPO/releases/download/$TAPLESS_VERSION"
    tag_label="$TAPLESS_VERSION"
  else
    base_url="https://github.com/$REPO/releases/latest/download"
    tag_label="последний релиз"
  fi

  local install_dir="${TAPLESS_INSTALL_DIR:-$HOME/Applications}"

  TMP_DIR="$(mktemp -d)"
  local tmp="$TMP_DIR"
  trap 'rm -rf "$TMP_DIR"' EXIT

  step "Скачиваю $APP_NAME ($tag_label)"
  if ! curl -fL --retry 3 --progress-bar -o "$tmp/$ASSET" "$base_url/$ASSET"; then
    if [[ -n "${TAPLESS_VERSION:-}" ]]; then
      fail "Не удалось скачать $ASSET: проверьте, что релиз $TAPLESS_VERSION существует (https://github.com/$REPO/releases) и есть сеть"
    fi
    fail "Не удалось скачать $ASSET: проверьте сеть и наличие релиза (https://github.com/$REPO/releases)"
  fi

  if curl -fsSL --retry 3 -o "$tmp/$ASSET.sha256" "$base_url/$ASSET.sha256" 2>/dev/null; then
    step "Проверяю контрольную сумму"
    verify_checksum "$tmp/$ASSET" "$tmp/$ASSET.sha256"
  else
    echo "⚠︎ У релиза нет $ASSET.sha256: контрольную сумму проверить нечем, продолжаю" >&2
  fi

  step "Распаковываю"
  mkdir -p "$tmp/unpacked"
  ditto -x -k "$tmp/$ASSET" "$tmp/unpacked"
  [[ -d "$tmp/unpacked/$APP_NAME.app" ]] || fail "В архиве нет $APP_NAME.app"

  step "Проверяю подпись"
  codesign --verify --deep --strict "$tmp/unpacked/$APP_NAME.app" || fail "Подпись $APP_NAME.app не прошла проверку"

  local was_running=0
  if [[ "${TAPLESS_SKIP_QUIT:-0}" != 1 ]] && pgrep -x "$APP_NAME" >/dev/null; then
    was_running=1
    quit_running_app
  fi

  mkdir -p "$install_dir"
  rm -rf "${install_dir:?}/$APP_NAME.app"
  mv "$tmp/unpacked/$APP_NAME.app" "$install_dir/$APP_NAME.app"
  xattr -dr com.apple.quarantine "$install_dir/$APP_NAME.app" 2>/dev/null || true
  step "Установлено: $install_dir/$APP_NAME.app"

  if [[ "${TAPLESS_NO_LAUNCH:-0}" == 1 ]]; then
    echo "▸ Запуск пропущен (TAPLESS_NO_LAUNCH=1)"
  else
    if [[ "$was_running" == 1 ]]; then
      step "Перезапускаю $APP_NAME на новой версии"
    else
      step "Запускаю $APP_NAME"
    fi
    open "$install_dir/$APP_NAME.app"
  fi

  echo
  echo "Дальше:"
  echo "  • Разрешите «Микрофон» и «Универсальный доступ» (Системные настройки → Конфиденциальность и безопасность)."
  echo "  • Запись — клавиша ⌥Э (в английской раскладке ⌥')."
  echo "  • Настройки — файл ~/.config/tapless.toml."
  if [[ ! -d /Applications/Ollama.app && ! -d "$HOME/Applications/Ollama.app" ]] && ! command -v ollama >/dev/null 2>&1; then
    echo "  • Ollama не найдена. Установите: brew install ollama или https://ollama.com/download/mac"
  fi
}

main "$@"
