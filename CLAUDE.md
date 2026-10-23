# CLAUDE.md

Инструкции для ИИ-агентов (Claude Code, Codex и др.). `AGENTS.md` — симлинк на этот файл, правьте только `CLAUDE.md`.

## Что это

**TapLess** — голосовой ввод для macOS, приложение живёт в меню-баре. Прежнее рабочее название — VoicePop; в коде и путях его не осталось.

Сценарий пользователя:

1. Горячая клавиша (`⌥Э` по умолчанию, `option+quote`) — запись с микрофона.
2. Речь локально распознаёт Whisper (WhisperKit, CoreML / Neural Engine).
3. Расшифровка **параллельно** уходит в N «вариантов» оформления (до 9). Каждый вариант — вызов harness (секция `[harness.<имя>]`): либо запуск внешней CLI-программы (текст в stdin или аргументом, результат из stdout, текст или JSON), либо запуск Codex CLI с отдельной папкой `CODEX_HOME` (`type = "codex"`), либо HTTP-запрос к локальному Ollama (`type = "ollama"`). По умолчанию это Ollama с моделью `gemma4:e4b-it-q4_K_M` (`llm.harness = "ollama"`). Пресет `claude` — `claude -p --model haiku …`, пресет `codex` — `codex exec --model gpt-6-luna …`; подходит любой CLI (OpenCode, `llm`, свой скрипт).
4. Во всплывающей панели пользователь жмёт цифру: `1` — сырой текст («Как распознано», `ui.show_raw`), `2–9` — варианты (без `show_raw` — `1–9`). Текст вставляется в приложение, которое было в фокусе (буфер обмена + синтетический `⌘V`).

Пользовательская документация — `README.md`. Значения конфига по умолчанию с комментариями — `config.default.toml`.

## Стек

- Swift (tools-version 5.10, язык Swift 5), SwiftPM, без Xcode-проекта.
- AppKit + SwiftUI (панель — `NSPanel` с `NSHostingView`), Carbon для глобальных горячих клавиш, AVFoundation для записи.
- Зависимости (`Package.swift`): `argmax-oss-swift` (продукт `WhisperKit`), `TOMLKit`.
- Платформа: только macOS 14+, только Apple Silicon (`arm64`).

## Сборка и запуск

```bash
swift build                                   # debug-сборка, быстрая проверка компиляции
swift build -c release --arch arm64           # то же, что делает build_app.sh
./build_app.sh                                # собрать build/TapLess.app
./build_app.sh --install                      # + установить в ~/Applications и запустить
./build_app.sh --zip                          # + архив build/TapLess.zip и build/TapLess.zip.sha256 для раздачи
./scripts/install.sh                          # установка последнего релиза из GitHub Releases (для проверки агентом: TAPLESS_INSTALL_DIR=<временная папка> TAPLESS_NO_LAUNCH=1 TAPLESS_SKIP_QUIT=1)
SIGN_IDENTITY="Имя" ./build_app.sh --install  # подпись другим сертификатом
```

- Первая сборка тянет зависимости и идёт несколько минут.
- `build_app.sh` сам вызывает `scripts/gen_default_config.sh`, затем собирает `.app` из бинарника и `Support/Info.plist`, затем `codesign`.
- `--install` убивает запущенный `TapLess` (`pkill -x`) и запускает новый. Не делайте этого без запроса пользователя: это меняет его рабочее окружение.
- Тесты: `./scripts/test.sh` (swift-testing, таргеты `TapLessDomainTests`, `TapLessDataTests`). Голый `swift test` с Command Line Tools падает: SwiftPM не находит плагин макросов `TestingMacros`, скрипт передаёт `-plugin-path` сам.
- Минимальная проверка изменения — `swift build` без ошибок и новых warnings плюс `./scripts/test.sh`. Линтера нет.
- Живая проверка harness из конфига пользователя (настоящий вызов LLM, без GUI): `TAPLESS_LIVE_LLM=1 ./scripts/test.sh --filter LiveLLM`. Лог теста — в файл из `TAPLESS_LIVE_LOG`. Без `TAPLESS_LIVE_LLM=1` эти тесты пропускаются.
- Проверяйте код выхода `swift build`. Пайп вроде `swift build | tail` прячет падение сборки (код выхода 0), поэтому используйте `set -o pipefail`.
- Предупреждения `ld: warning: search path '/Library/Developer/CommandLineTools/Developer/...' not found` — особенность Command Line Tools, к коду не относятся.

### Сборка без Xcode: не используйте макросы SwiftUI

Проект должен собираться одними Command Line Tools (проверено: Swift 6.4, SDK macOS 27). В новых SDK часть SwiftUI-обёрток стала макросами (`@State` → `SwiftUIMacros.StateMacro`, также `#Preview`, `@Entry`). Плагина `SwiftUIMacros` в Command Line Tools нет, и сборка падает с ошибкой `external macro implementation type 'SwiftUIMacros.…' could not be found`.

- Не используйте `@State`, `#Preview`, `@Entry`. Локальное состояние вью храните в `ObservableObject` (`@ObservedObject` / `@StateObject`) или используйте модификаторы без состояния (`.phaseAnimator`, `TimelineView`), как в `PulsingDot` в `Presentation/Popup/PopupView.swift`.
- `@Observable` работает: плагин `ObservationMacros` в Command Line Tools есть.

### Ограничения проверки агентом

- Микрофон, глобальные клавиши, вставка `⌘V` и панель требуют GUI-сессии и разрешений TCC. Из агента это не проверить — опишите пользователю шаги ручной проверки.
- Подпись: `build_app.sh` подписывает сертификатом `TapLess Dev`, если он есть в Связке ключей (`security find-identity -p codesigning`), иначе ad-hoc. Статус `CSSMERR_TP_NOT_TRUSTED` у самоподписанного сертификата — норма, `codesign` им подписывает. При ad-hoc подписи после **каждой** пересборки macOS сбрасывает разрешения «Микрофон» и «Универсальный доступ». Если пользователь жалуется, что вставка перестала работать после сборки, — проверьте подпись: `codesign -dr - ~/Applications/TapLess.app` (см. README, «Сборка из исходников»).
- Команду LLM можно проверить без GUI, вручную (пример в `skills/tapless-config/SKILL.md`, «Переключить все варианты на Claude Code»).

## Архитектура

Чистая архитектура: три SwiftPM-таргета, зависимости только сверху вниз.

```
┌──────────────────────────────────────────────────────────────┐
│ TapLess (executable) — AppKit, SwiftUI, Carbon, AVFoundation │
│   main.swift      composition root: создаёт реализации из    │
│                   TapLessData и передаёт их в AppController  │
│   Presentation/   AppController, Popup/ (Model, Controller,  │
│                   View)                                      │
│   Platform/       AudioRecorder, HotKeys, Paster             │
└───────────────┬──────────────────────────────┬───────────────┘
                │ import (только main.swift)   │ import
                ▼                              │
┌───────────────────────────────────┐          │
│ TapLessData — WhisperKit, TOMLKit │          │
│   Config/  FileConfigRepository   │          │
│   LLM/     ProcessLLMRepository,  │          │
│            CodexLLMRepository,    │          │
│            OllamaLLMRepository,   │          │
│            RoutingLLMRepository,  │          │
│            OllamaSetup            │          │
│   STT/     WhisperSpeechRecognizer│          │
│   AppPaths, Logging/AppLog        │          │
└───────────────┬───────────────────┘          │
                │ import                       │
                ▼                              ▼
┌──────────────────────────────────────────────────────────────┐
│ TapLessDomain — только Foundation                            │
│   Models/          AppConfig, AudioClip, LLMRequest          │
│   UseCases/        TranscribeSpeechUseCase,                  │
│                    FormatTextUseCase, PrepareLocalLLMUseCase │
│   Repositories/    протоколы ConfigRepository, LLMRepository │
│   Services/        протоколы SpeechRecognizer, LocalLLMSetup │
│   TextProcessing/  TextTools: словарь для промпта, чистка    │
│   Logging/         Log — фасад, sink ставит TapLessData      │
└──────────────────────────────────────────────────────────────┘
```

Правила слоёв:

- `TapLessDomain` не импортирует ничего, кроме Foundation. Внешние данные (конфиг, LLM) — через протоколы репозиториев, STT — через протокол `SpeechRecognizer`.
- `TapLessData` импортирует только `TapLessDomain` и внешние библиотеки. Типы, нужные снаружи, — `public`, остальное `internal`.
- В таргете `TapLess` `import TapLessData` есть только в `main.swift`. Файлы `Presentation/` и `Platform/` импортируют только `TapLessDomain`. Новая зависимость контроллера добавляется полем в `AppDependencies` и создаётся в `main.swift`.
- Логика разбора текста — в use case-ах Domain, а не в `AppController`. Контроллер отвечает за состояние, UI и порядок вызовов.
- Логи пишутся через `Log.debug` / `info` / `warning` / `error` с категорией `LogCategory` (Domain). Приёмник (файл + Unified Logging) подключает `AppLog.install` в `main.swift`, уровень и `include_text` — из секции `[log]`. Текст диктовки и ответов LLM в лог — только через `Log.text(...)`: без `include_text` он заменяется длиной.

### Поток данных

```
hotkey ─► AppController.startRecording ─► AudioRecorder.start
hotkey ─► stopRecording ─(tail_ms)─► finishRecording
            │  AudioClip (16 кГц)
            ▼
        TranscribeSpeechUseCase.rejection   (слишком коротко / тишина)
        TranscribeSpeechUseCase.execute
            │  SpeechRecognizer.transcribe  (WhisperKit, подсказка stt.initial_prompt)
            │  TextTools.cleanTranscript   (без замен: термины правит только LLM)
            ▼
        startVariants ─► runVariant × N (параллельно, Task на вариант;
            │              N = runVariantKeys(autoSelectKey:): при автовставке — один)
            │  FormatTextUseCase.execute ─► LLMRequest
            │    systemPrompt = base_prompt({dictionary}) + variant.prompt
            │    input        = input_template({text})
            │    harness      = harnesses[variant.harness ?? llm.harness]
            │    model        = variant.model ?? harness.model ?? llm.model
            │    schema       = schemas[variant.schema]   (необязательно)
            │  LLMRepository.complete ─► RoutingLLMRepository (по harness.type)
            │    process: ProcessLLMRepository
            │      prompt-<N>.txt, schema-<N>.json
            │      zsh -l -c '"$0" "$@"' executable args+text_args|schema_args
            │      stdout ─► HarnessOutputParser (text | json по пути)
            │    codex:   CodexLLMRepository ─► CodexHome.prepare ─► ProcessLLMRepository
            │      CODEX_HOME = codex-home (auth.json → ~/.codex, провайдер из config.toml)
            │    ollama:  OllamaLLMRepository
            │      POST <url>/api/chat (system + user, stream=false, format=схема)
            │      message.content ─► HarnessOutputParser (если есть схема)
            ▼
        finishVariant ─► PopupModel.variants[N] = done / failed
            │
  цифра ────┴─► select ─► deliver ─► Paster.deliver (clipboard + ⌘V в targetApp)

✎ / ⌥+цифра ─► beginEdit ─► state = editing, поле замечаний (панель key)
            │  ⌥Э ─► запись замечания ─► Whisper ─► FormatTextUseCase.cleanFeedback
            │       (llm.feedback_prompt, ключ 0; ошибка — текст как распознан) ─► model.feedback
  ↩ ────────┴─► submitEdit ─► FormatTextUseCase.revise
                 systemPrompt = base_prompt + variant.prompt + revise_prompt
                 input        = revise_template({text}, {previous}, {feedback})
               ─► finishRevision ─► строка = done(новый текст), прежний — в history
                                    ошибка: прежний текст + model.note
↶ / ⌥⇧+цифра ─► undoRevision ─► строка = последняя версия из history

История (DictationHistoryUseCase ─► FileHistoryRepository, ~/.cache/tapless):
  finishRecording ─► .recording (WAV), .transcript      deliver ─► .delivered, затем prune
  запись замечания ─► .feedbackRecording, .feedbackTranscript
  любой вызов LLM в HistoryContext.$session.withValue(sid) ─► HistoryLLMRepository ─► .llmCall
```

### История диктовок
- **Что пишется.** Пишет `DictationHistoryUseCase` (Domain) через протокол `HistoryRepository`. Реализация — `FileHistoryRepository` (Data, `actor`). Вызовы LLM записывает декоратор `HistoryLLMRepository` вокруг `RoutingLLMRepository` (собирается в `main.swift`).
- **Привязка вызова LLM к диктовке.** Сессию декоратор берёт из `@TaskLocal HistoryContext.session`. Новый вызов LLM от имени диктовки оборачивайте в `HistoryContext.$session.withValue(sid) { … }`, иначе он в историю не попадёт. Прогрев (`LLMPurpose.warmUp`) не пишется.
- **Запись не тормозит работу.** `AppController.recordHistory` пишет в фоновой задаче и берёт время события в момент вызова. Ошибки ввода-вывода — только в лог.
- **Чистка.** `pruneHistory` запускается при старте и после вставки, одновременно идёт одна. Чистит по `retention_days` и `max_size_mb`, но последнюю диктовку не удаляет. При `enabled = false` чистка тоже идёт.

### Ключевые инварианты

- **State machine** в `AppController`: `idle → recording → transcribing → results → idle`, плюс `message` для уведомлений и `editing` (правка строки, из `results` и обратно). Переходы — только на главном потоке (`@MainActor`).
- **Сессии.** Каждая запись создаёт новый `session = UUID()`. Все асинхронные колбэки (распознавание, варианты, автостоп) сверяют `session == sid` и молча выходят, если сессия сменилась. Новый асинхронный код должен соблюдать это правило.
- **Отмена вариантов.** Каждый вариант — отдельный `Task` в `jobs`. `cancelJobs()` отменяет их; `ProcessLLMRepository` при отмене завершает процесс, `OllamaLLMRepository` — HTTP-запрос; оба бросают `CancellationError`, которую `finishVariant` игнорирует.
- **Старт записи.** `startRecording` сначала проверяет микрофон и запускает `AudioRecorder`, и только потом отменяет прежние варианты и меняет `session`. Если запись не стартовала, прежние результаты доступны через «Показать последний результат».
- **Распознавание** идёт в `transcribeTask`; `Esc` и новая запись его отменяют. Пока задача жива (Whisper может ещё работать после отмены), «Перезагрузить модель» недоступна (`canReloadModel`).
- **Смена микрофона.** `AudioRecorder.onConfigurationChange` → `AppController.audioConfigurationChanged`: через 300 мс движок перезапускается на новом устройстве с сохранением записанного; если не вышло — `stopRecording` и распознавание того, что есть.
- **Клавиши панели.** Раскладку задаёт Domain: `AppConfig.rawTextKey` (`1` при `ui.show_raw`, иначе nil), `firstVariantKey` (2 или 1), `maxVariants` (8 или 9). `FormatTextUseCase` принимает и возвращает клавиши (`variantKeys`, `variant(forKey:)`), не индексы; `VariantState.id`, `LLMRequest.variantKey`, `prompt-<N>.txt` и `TAPLESS_VARIANT` — тоже клавиша. Сырой текст выбирается клавишей `model.rawKey`.
- **Отложенный выбор.** Цифру можно нажать до готовности варианта: она сохраняется в `model.pendingKey`, и вставка происходит в `finishVariant` (для правки — в `finishRevision`).
- **Автовставка** (`paste.auto_select`, `PasteConfig.autoSelect`). Меняется на ходу из меню (подменю «Автовставка», `AppController.setAutoSelect`), поэтому живёт в контроллере (`autoSelectKey`, начальное — `AppConfig.autoSelectKey`), а Domain принимает её параметром: `AppConfig.runVariantKeys(autoSelectKey:)` — варианты, которые запускаются на диктовку (при автовставке только её вариант, при автовставке сырого текста — ни одного), `FormatTextUseCase.runKeys(autoSelectKey:)` и `warmUpKeys(autoSelectKey:)`. `ollamaTargets` и `codexTargets` автовставку не учитывают: подготовка идёт при запуске, а выбор может смениться. Выбор из меню пишется в файл пользователя `ConfigRepository.setInteger` (`TOMLLineEditor`: меняет одну строку, итог проверяется разбором; не вышло — файл не тронут, выбор действует до перезапуска). Автовставка — отложенный выбор: `stopRecording` ставит `model.pendingKey = autoSelectKey`, дальше обычный путь `finishVariant` → `select` → `deliver`. Строки панели и сессионные цифры — только запущенные варианты (`model.variants`), иначе цифру невидимого варианта перехватывал бы глобальный хоткей. `PopupModel.autoKey` / `autoName` — для заголовка; значок «Автовставка N» виден, пока `pendingKey == autoKey`.
- **Правка строки** (`state == .editing`). Вход — ✎ или `⌥+цифра`, только из `results` и только для готовой строки (`FormatTextUseCase.canRevise`). В правке сняты цифры: Carbon перехватил бы их раньше поля; остаётся `Esc` (`escapePressed`: отмена записи замечания, потом — отмена правки). Главная клавиша пишет **замечание** (`feedbackTask`, свой автостоп; после Whisper — чистка `cleanFeedback`, фаза `polishing`), а не новую диктовку; ошибки — в `model.note`, не `showMessage`. Панель — `PopupPanel`: `canBecomeKey` только в правке (`beginEditing` / `endEditing`), приложение-цель остаётся активным. Правка — `Task` в `jobs` и `revisionJobs[key]`: новая правка той же строки отменяет прежнюю. Если правка не удалась, строка получает прежний текст. Удачная правка кладёт прежний текст в историю строки (`VariantState.history`, для сырого текста — `model.rawHistory`); `undoRevision` (↶, `⌥⇧+цифра`) снимает по одной версии до исходной. Сырой текст правится через `llm.harness`, `rawText` остаётся исходной расшифровкой (`{text}`), результат — `model.rawRevision`. Любой выход из `editing` идёт через `leaveEditing`: он останавливает запись замечания и возвращает клавиатуру.
- **Клавиша «Показать последний результат»** (`general.show_last_hotkey`, по умолчанию `option+semicolon`, `⌥Ж`) регистрируется глобально при запуске, как и клавиша записи. `showLastHotKeyDown`: в `results` закрывает панель, в `idle` / `message` вызывает `showLastResult` (или сообщение, если результатов нет), во время записи и распознавания игнорируется. Пустая строка выключает клавишу.
- **Сессионные клавиши.** Цифры, `⇧+цифры`, `⌥+цифры`, `⌥⇧+цифры` и `Esc` регистрируются глобально только пока панель открыта (`registerSessionKeys` / `unregisterSessionKeys`). Любой путь закрытия панели обязан снимать их, иначе цифры перестанут работать в других приложениях.
- **Строки панели** — `Button` со стилем `VariantRowButtonStyle`: подсветка под курсором и сжатие при нажатии. Наведение ловит свой `NSTrackingArea` с `.activeAlways` (`HoverTracker`), потому что TapLess не активное приложение; после `orderOut` / показа панели он сверяет курсор по `didChangeOcclusionState`.
- **Панель не забирает фокус** (`.nonactivatingPanel`). `targetApp` запоминается в момент старта записи; вставка идёт туда.
- **Команда LLM** запускается через `posix_spawn` в отдельной группе процессов (`ProcessJob`): таймаут и отмена шлют SIGTERM всей группе, через 2 с — SIGKILL; после выхода shell оставшиеся в группе потомки добиваются. Не возвращайтесь к `Foundation.Process`: он не умеет группу, и потомки (`claude`) остаются сиротами. Harness запускается через `llm.shell` (`/bin/zsh`) как `-l -c '"$0" "$@"' executable args…`: аргументы идут как argv, без shell-разбора, поэтому плейсхолдеры (`{model}`, `{prompt_file}`, `{system_prompt}`, `{input}`, `{schema}`, `{schema_file}`) подставляются **без** экранирования. Не добавляйте `exec` в скрипт запуска: `executable` может быть функцией shell из `~/.zshenv` (например, `claude-proxy-dang`), а функции через `exec` не запускаются. Код выхода 127 — «программа не найдена» (`LLMError.notFound`). Рабочая папка по умолчанию — пустая `~/Library/Application Support/TapLess/llm-workdir`, чтобы `claude` не подхватил чужой `CLAUDE.md`.
- **Ollama** (`type = "ollama"`) — прямой HTTP-запрос через `URLSession`, без процессов: `POST <url>/api/chat`, `stream: false`, `think`, `keep_alive`, `options`, схема — в `format`. Ключи CLI (`executable`, `args`, `input`, `output`…) для него не используются, `executable` обязателен у `type = "process"` и `"codex"`. Загрузку и проверку схемы обе реализации берут из `SchemaSource`. Новый тип harness — новый `case` в `HarnessKind`, своя реализация `LLMRepository` и ветка в `RoutingLLMRepository` (пример — `codex`). Живой проверки Ollama в тестах нет: HTTP подменяется `URLProtocol`.
- **Очередь harness.** `parallel` в `[harness.<имя>]` (у `ollama` по умолчанию 3, `0` — без ограничения) ограничивает число одновременных запросов: `RoutingLLMRepository` берёт слот в `RequestLimiter` (actor; ключ очереди — `queueKey`: url сервера для Ollama, имя harness для CLI). При объединении `parallel` нескольких harness `0` важнее числа (`OllamaTarget.combinedParallel`). Отменённый запрос уходит из очереди с `CancellationError`. Слот освобождается на любом выходе из `route`, иначе очередь встанет.
- **Claude Code** (пресет `claude`) — `--system-prompt-file` заменяет системный промпт, `--tools ""` убирает инструменты, но без `--safe-mode` в первое сообщение подмешивается `~/.claude/CLAUDE.md` пользователя, а в системные блоки — `language` из `~/.claude/settings.json`; ещё запускаются его хуки. Поэтому в `args` есть `--safe-mode` (выключает `CLAUDE.md`, навыки, плагины, хуки, MCP; вход по подписке работает) и `--settings '{"language":""}'`. `--setting-sources ""` не используется: он отключил бы и `env` / `apiKeyHelper` из настроек, через которые у пользователя может идти вход. Остаётся блок `# Environment` (~900 символов): с `--system-prompt` его не убрать. `--bare` (пресет `claude-bare`) чище всех, но работает только с API-ключом. Проверено подменой `ANTHROPIC_BASE_URL` на локальный сервер, который пишет тело запроса.
- **Codex** (`type = "codex"`) — тот же запуск CLI, что у `process` (`CodexLLMRepository` оборачивает `ProcessLLMRepository`), но с `CODEX_HOME` = `~/Library/Application Support/TapLess/codex-home`. Флага «не читать `~/.codex/AGENTS.md`» у `codex exec` нет: `--ignore-user-config` пропускает только `config.toml`, а `model_instructions_file` заменяет встроенный промпт, но глобальный `AGENTS.md` всё равно подмешивается (проверено на 0.160). `CodexHome` пересобирает папку при изменении исходного `config.toml` или `auth.json`: `auth.json` — символическая ссылка на файл пользователя (обновлённый токен пишется в оригинал), `config.toml` — ключи `CodexHome.inheritedKeys` (провайдер, вход) плюс выключенные `analytics`, `feedback`, `otel`, `web_search` и фичи-инструменты. `analytics.enabled = false` обязателен: без него `codex exec` после ответа ждёт отправку метрик до 10 с. Источник — `CODEX_HOME` из `[harness.<имя>.env]`, `[llm.env]`, окружения, иначе `~/.codex`. Фичи выключаются в `config.toml`, а не флагом `--disable`: на незнакомое имя `--disable` падает, а ключ в `config.toml` даёт только предупреждение. Codex повторяет вход и ответ в stderr, поэтому `ProcessJob` пишет stderr удачного запуска в лог только при `include_text`. Часть инструментов (`exec`, `wait`, `collaboration.*`) включает не `[features]`, а профиль модели (`tool_mode`, `multi_agent_version` в `models_cache.json`), поэтому `CodexHome.makeCatalog` пишет `model-catalog.json` — копию свежего `models_cache.json` (своей папки или пользователя) без этих ключей, — и ставит `model_catalog_json`; `request_user_input` и `update_plan` выключают `tools.experimental_request_user_input` / `tools.update_plan = {enabled = false}` (иначе они приходят элементом `additional_tools` во `input`), `skills.include_instructions = false` убирает блок `<skills_instructions>` (~2000 символов, навыки из `CODEX_HOME/skills/.system`), а `include_*_instructions = false` — ~4000 токенов служебных инструкций. Поле `"tools"` в SSE-ответе — эхо, а не запрос: смотрите тело `POST /responses` (так делает проверка изоляции). С `model_catalog_json` Codex свой `models_cache.json` больше не обновляет, поэтому свежий каталог приходит из `~/.codex`. Кэша нет нигде — `CodexLLMRepository` один раз за запуск TapLess (`OnceTask`, параллельные варианты ждут одну задачу) вызывает `executable debug models --bundled` и сохраняет `bundled-models.json`; он только запасной, любой кэш важнее. Не вышло — каталога нет, инструменты профиля остаются (предупреждение в лог). `project_doc_max_bytes = 0` дополнительно запрещает `AGENTS.md` из рабочей папки. `auth.json` — именно ссылка, не копия: Codex пишет обновлённый токен через ссылку в оригинал (проверено с `CODEX_REFRESH_TOKEN_URL_OVERRIDE`), а копия оставила бы в `~/.codex` уже аннулированный refresh-токен. `--strict-config` в `args` нет: при обновлении Codex исчезнувшее имя фичи стало бы ошибкой каждого вызова.
- **Проверка изоляции Codex** (`CodexIsolationVerifier`, Data; `CheckCodexUseCase`, Domain). Цели — `AppConfig.codexTargets`: harness `type = "codex"` и модели включённых вариантов плюс `llm.harness` (чистка замечаний, правка сырого текста). Проверка — пробный запуск Codex с аргументами harness, конфигом `CodexHome.makeConfigTable` и каталогом из `codex-home`, но во временном `CODEX_HOME` с провайдером `tapless-verify` (`env_key`) на `LoopbackCapture` (`NWListener`, 127.0.0.1). Сервер отвечает 400, Codex выходит за ~0,4 с без повторов (в логе — ожидаемая ошибка «ответ 400 ожидаем»). `analyze` разбирает тело: во `input` допустимы только сообщение developer с нашим промптом, сообщение user с нашим текстом и пустой `additional_tools`; ещё сверяются модель и `model_reasoning_effort` из `args`. В рабочей папке лежит `AGENTS.md` с меткой: метка в запросе блокирует harness при любом `verify`, иначе блокирует только `verify = "block"` (`LLMError.blocked` из `CodexLLMRepository.complete`). Полная проверка идёт, только если изменился отпечаток (`fingerprint`: `--version`, `config.toml` и `model-catalog.json` из `codex-home`, аргументы, модель, окружение, `checkVersion` — поднимайте его при изменении проверки или конфига Codex); итоги — `codex-check.json`. Когда: при запуске (`AppController.startCodexCheck`), перед вызовом раз в сутки и после пересборки папки (`CodexHome.generation`; при `block` — с ожиданием, иначе в фоне, итог — через `setReportHandler`), по пункту меню «Проверить Codex снова» (`force`). Не удалось проверить (нет Codex, нет запроса) — только лог, итог не сохраняется. Проблемы — предупреждение один раз на проверку: сообщение в панели или строка `model.note` при следующей диктовке, плюс строка «⚠︎ Codex …» в меню.
- **Подготовка Ollama.** `PrepareLocalLLMUseCase` берёт `AppConfig.ollamaTargets` (сервер + модель для каждого включённого варианта с `type = "ollama"`) и вызывает `OllamaSetup` (Data). Тот проверяет `GET /api/version`; если сервер локальный и молчит — запускает `Ollama.app` (`open -g --env … -a`), а если её нет, CLI `ollama serve` (`OllamaServe`: `posix_spawn` с `setsid`, сервер переживает TapLess, вывод — `~/Library/Logs/TapLess/ollama.log`, окружение — только базовые переменные и `OLLAMA_*`, без прокси и секретов; унаследованные `OLLAMA_FLASH_ATTENTION` / `OLLAMA_KV_CACHE_TYPE` важнее наших; `OllamaServerProcess` сообщает о раннем выходе, и подготовка падает сразу, без 30 с ожидания) и ждёт до 30 с. Переменные сервера — `OllamaSetup.serverEnvironment`: `OLLAMA_HOST` из url, `OLLAMA_NUM_PARALLEL` = max `parallel`, flash attention, KV-кэш q8_0. Уже запущенный сервер не перезапускается; сверяет `/api/tags` и докачивает модели через `POST /api/pull` (stream, прогресс по слоям). Итог — `LocalLLMStatus`: `ready`, `notInstalled`, `notRunning`, `failed`. `AppController` запускает подготовку при старте, по пункту меню «Проверить Ollama снова» и после ошибки варианта с harness Ollama; одновременно идёт одна подготовка (`localLLMTask`). Варианты не ждут подготовку: пока модель не готова, они падают с ошибкой, а в панели видна строка «Ollama: …». После `ready` контроллер прогревает кэш промпта (`warmUpTask`, `FormatTextUseCase.warmUp`): для каждого варианта с Ollama — тот же системный промпт, пустой текст и `num_predict = 1`; иначе первая диктовка разбирает промпт со словарём (~1300 токенов) с нуля, это 2–4 с. Новая диктовка прогрев отменяет: он делит с вариантами GPU. Модель по умолчанию не выгружается (`keep_alive = "-1"`), иначе через час простоя кэш пропадает вместе с ней. Установку и запуск Ollama в тестах подменяет `OllamaInstallation`.
- **Словарь — только для LLM.** Regex-замен нет: ошибки распознавания исправляет модель по `[dictionary.terms]` («термин» = [«как может прийти из распознавания»]) и `notes` — `TextTools.dictionaryBlock` подставляет их в `{dictionary}`. Whisper получает только статичный `stt.initial_prompt`: у WhisperKit 224 токена на окно до 30 с, подсказка отнимает их у текста, поэтому `WhisperSpeechRecognizer.maxPromptTokens` = 48 (подсказка на 111 токенов обрывала речь на 15-й секунде). Не возвращайте словарь в подсказку Whisper и замены в `TranscribeSpeechUseCase`.
- **Модель Whisper** считается скачанной только при наличии маркера `.tapless-complete` в её папке. Если `stt.model_path` пуст и модели нет, запуск приложения начинает скачивание (~1,6 ГБ для `large-v3-turbo`). Для пробного запуска из агента задайте несуществующий `stt.model_path` во временном конфиге через `TAPLESS_CONFIG`.

## Конфиг: правила изменения

Итоговый конфиг = встроенные значения по умолчанию + файл пользователя `~/.config/tapless.toml` поверх них (`FileConfigRepository`):

- Конфиг читается **один раз при запуске** (`main.swift`) и дальше не меняется. Чтобы применить правку, приложение перезапускают: меню → «Перезапустить (применить конфиг)». Не добавляйте горячую перезагрузку без запроса пользователя.
- Слияние (`ConfigMerge.merge`) идёт на уровне TOML-таблиц: таблицы сливаются по ключам рекурсивно, массивы и скаляры из файла заменяют дефолт целиком.
- Смысловые проверки значений (`mode`, `position`, `log.level`, число включённых вариантов, ссылки на несуществующий harness или схему, `input = "arg"` без `{input}`) — `AppConfig.validationWarnings` в Domain, тоже предупреждения.
- Ключи файла, которых нет в дефолтах, — предупреждения (`ConfigMerge.unknownKeys`). Таблицы со свободными ключами (`llm.env`, `dictionary.terms`) перечислены в `ConfigMerge.freeFormTables`; варианты — таблицы `[variants.<номер>]` (`ConfigMerge.namedTables`, как harness и схемы), их ключи сверяются с `ConfigDTO.variantKeys`. Новый номер добавляет вариант (`prompt` обязателен), ключи существующего номера заменяют только себя; старый массив `[[variants]]` — ошибка конфига. У `[harness.<имя>]` и `[schemas.<имя>]` имена свободные, а ключи внутри сверяются с `ConfigDTO.harnessKeys` / `schemaKeys` (`env` у harness — свободная таблица).
- У `[harness.<имя>]` и `[schemas.<имя>]` в DTO все ключи, кроме `executable`, необязательные: новый harness можно описать одной строкой. Неверные `input` / `output` — ошибка конфига с путём ключа.
- Если файл не разбирается, приложение работает на дефолтах и показывает ошибку. Битые встроенные дефолты — `fatalError` (это ошибка сборки, её ловят тесты).
- Приложение файл пользователя **не перезаписывает**. Единственное исключение — меню «Автовставка»: `setInteger` меняет или дописывает одну строку `paste.auto_select`, остальное не трогает. Если файла нет, `saveTemplateIfMissing` создаёт шаблон: пояснение + закомментированная копия дефолтов (`ConfigTemplate`). Шапка `config.default.toml` (первые строки-комментарии) в шаблон не копируется.

Значения по умолчанию живут в **одном** месте — `config.default.toml`. Из него `./scripts/gen_default_config.sh` генерирует `Sources/TapLessData/Config/DefaultConfig.swift` (руками не править; скрипт падает, если в TOML есть `"""#` или `\#`). Структуры в `AppConfig.swift` и `ConfigDTO.swift` значений по умолчанию не содержат.

Новый ключ конфига:

1. Добавить поле в Domain-модель (`TapLessDomain/Models/AppConfig.swift`) и в её `public init`.
2. Добавить поле в DTO (`TapLessData/Config/ConfigDTO.swift`): `CodingKeys` (snake_case в TOML) и перенос в `.domain`. Для вариантов `[variants.<номер>]` — ещё в `ConfigDTO.variantKeys`; поле там optional со значением по умолчанию в `.domain`.
3. Добавить ключ с комментарием в `config.default.toml` и запустить `./scripts/gen_default_config.sh`.
4. Запустить `./scripts/test.sh`: тест `defaultsParse` проверяет, что дефолты разбираются.
5. Если ключ виден пользователю — описать в `README.md` и в `skills/tapless-config/SKILL.md`.

`skills/tapless-config/SKILL.md` — публичная инструкция для сторонних ИИ-агентов: как читать и менять `~/.config/tapless.toml`, словарь, сценарии (в том числе пополнение словаря по истории диалогов). README ссылается на неё по raw-URL ветки `main`. При изменении ключей, правил слияния, клавиш панели или путей обновляйте и её.

## Файлы на машине пользователя

| Что | Путь |
|---|---|
| Конфиг пользователя | `~/.config/tapless.toml` (путь меняется env `TAPLESS_CONFIG`) |
| Модели Whisper | `~/Library/Application Support/TapLess/models` |
| Промпты и схемы вариантов | `~/Library/Application Support/TapLess/run/prompt-<N>.txt`, `schema-<N>.json` |
| История диктовок | `~/.cache/tapless/history/<гггг-мм-дд>/<чч-мм-сс>_<сессия>/` (`session.json`, `audio.wav`, `transcript.txt`, `llm/`), промпты — `~/.cache/tapless/prompts/<id>.txt`; папка — `history.dir` |
| Рабочая папка LLM | `~/Library/Application Support/TapLess/llm-workdir` |
| `CODEX_HOME` для `type = "codex"` | `~/Library/Application Support/TapLess/codex-home` (пересоздаётся TapLess) |
| Итоги проверок изоляции Codex | `~/Library/Application Support/TapLess/codex-check.json` |
| Лог | `~/Library/Logs/TapLess/TapLess.log` (при > 5 МБ переименовывается в `TapLess.log.1`; в DEBUG-сборке дублируется в stderr) и Unified Logging: подсистема `io.github.aaudin90.tapless`, `/usr/bin/log stream --level debug --predicate 'subsystem == "io.github.aaudin90.tapless"'` (в zsh `log` — встроенная команда, поэтому полный путь) |

## Соглашения

- Комментарии, doc-комментарии, тексты UI и сообщения лога — на русском. Сохраняйте этот стиль.
- Отступ 4 пробела, стиль кода — как в существующих файлах. Форматтера нет.
- Новые типы, которые трогают UI или состояние приложения, помечайте `@MainActor`. Фоновые операции — `actor` или `@unchecked Sendable` с явным `NSLock`, как в `AudioRecorder` и `ProcessJob`.
- Ошибки для пользователя — `enum …Error: LocalizedError` с русским `errorDescription`.
- Не коммитьте `build/`, `.build/`, `.swiftpm/`, `.idea/` (есть в `.gitignore`). `Package.resolved` коммитится: он фиксирует версии зависимостей.
- Версия приложения — `CFBundleShortVersionString` / `CFBundleVersion` в `Support/Info.plist`.
