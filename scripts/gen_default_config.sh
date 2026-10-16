#!/usr/bin/env bash
# Встраивает config.default.toml в бинарник (Sources/TapLessData/Config/DefaultConfig.swift).
# Это настройки по умолчанию; ~/.config/tapless.toml переопределяет их поверх.
set -euo pipefail
cd "$(dirname "$0")/.."
src="config.default.toml"
out="Sources/TapLessData/Config/DefaultConfig.swift"
if grep -q '"""#' "$src" || grep -q '\\#' "$src"; then
  echo "В $src есть последовательность, ломающая raw-строку Swift" >&2
  exit 1
fi
{
  printf '// Сгенерировано scripts/gen_default_config.sh из config.default.toml — не править руками.\n\n'
  printf 'enum DefaultConfig {\n    static let toml = #"""\n'
  cat "$src"
  printf '\n"""#\n}\n'
} > "$out"
echo "Обновлён $out"
