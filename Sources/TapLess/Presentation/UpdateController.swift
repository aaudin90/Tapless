import AppKit
import TapLessDomain

/// Проверка обновлений на GitHub: фоновая проверка раз в сутки, пункты меню,
/// подтверждение и установка. Сама замена `.app` идёт после выхода TapLess (`AppUpdater.scheduleInstall`).
@MainActor
final class UpdateController: NSObject {
    private enum Phase: Equatable {
        case idle, checking, downloading
    }

    private let update: CheckUpdateUseCase
    /// Можно ли сейчас завершить приложение: не во время записи, распознавания и правки.
    var canInstall: () -> Bool = { true }
    /// Уведомление о новой версии: панелью, если она свободна, иначе строкой при следующей диктовке.
    var notify: (String) -> Void = { _ in }

    private var phase: Phase = .idle
    /// Найденный релиз новее текущей версии.
    private var available: AppRelease?
    private var lastError: String?
    private var loopTask: Task<Void, Never>?
    private var job: Task<Void, Never>?

    /// О какой версии уже уведомили: одно уведомление на версию, и после перезапуска тоже.
    private static let notifiedKey = "update.notifiedVersion"

    init(update: CheckUpdateUseCase) {
        self.update = update
        super.init()
    }

    /// Фоновая проверка: первая — через `firstCheckDelay` после запуска, дальше — раз в `interval`.
    func start() {
        guard update.isAvailable else {
            Log.info("Обновления: не из .app или нет версии — проверка выключена", .app)
            return
        }
        guard update.checksAutomatically else {
            Log.info("Обновления: фоновая проверка выключена (general.check_updates = false)", .app)
            return
        }
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CheckUpdateUseCase.firstCheckDelay * 1_000_000_000))
            while !Task.isCancelled {
                self?.check(manual: false)
                try? await Task.sleep(nanoseconds: UInt64(CheckUpdateUseCase.interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        job?.cancel()
    }

    // MARK: - Меню

    /// Пункты для меню-бара: найденная версия или «Проверить обновления».
    func menuItems() -> [NSMenuItem] {
        guard update.isAvailable else { return [] }
        var items: [NSMenuItem] = []
        func add(_ title: String, _ selector: Selector?) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.isEnabled = selector != nil
            items.append(item)
        }
        switch phase {
        case .downloading:
            add("Скачиваю обновление \(available.map { "\($0.version)" } ?? "")…", nil)
        case .checking:
            add("Проверяю обновления…", nil)
        case .idle:
            if let available {
                add("⬆︎ Обновить TapLess до \(available.version)…", #selector(installAction))
            }
            add("Проверить обновления", #selector(checkAction))
        }
        if let lastError, phase == .idle { add("⚠︎ Обновления: \(lastError)", nil) }
        return items
    }

    @objc private func checkAction() {
        Log.info("Меню: Проверить обновления", .app)
        check(manual: true)
    }

    @objc private func installAction() {
        Log.info("Меню: Обновить TapLess до \(available.map { "\($0.version)" } ?? "—")", .app)
        guard let available else { return }
        offer(available)
    }

    // MARK: - Проверка

    private func check(manual: Bool) {
        guard phase == .idle else { return }
        phase = .checking
        let update = self.update
        job = Task { [weak self] in
            let result: Result<AppRelease?, Error>
            do {
                result = .success(try await update.check())
            } catch {
                result = .failure(error)
            }
            self?.finishCheck(result, manual: manual)
        }
    }

    private func finishCheck(_ result: Result<AppRelease?, Error>, manual: Bool) {
        phase = .idle
        job = nil
        let current = update.currentVersion.map { "\($0)" } ?? "?"
        switch result {
        case .failure(let error):
            if error is CancellationError { return }
            lastError = error.localizedDescription
            Log.warning("Обновления: проверка не удалась: \(error.localizedDescription)", .app)
            if manual {
                showAlert(title: "Не удалось проверить обновления", text: error.localizedDescription)
            }
        case .success(nil):
            lastError = nil
            available = nil
            Log.info("Обновления: установлена последняя версия \(current)", .app)
            if manual {
                showAlert(title: "Обновлений нет", text: "У вас последняя версия TapLess \(current).")
            }
        case .success(let release?):
            lastError = nil
            available = release
            Log.info("Обновления: доступна версия \(release.version) (сейчас \(current))", .app)
            if manual {
                offer(release)
            } else if UserDefaults.standard.string(forKey: Self.notifiedKey) != release.tag {
                UserDefaults.standard.set(release.tag, forKey: Self.notifiedKey)
                notify("Доступен TapLess \(release.version). Обновить — в меню TapLess.")
            }
        }
    }

    // MARK: - Установка

    /// Окно с описанием релиза: обновить, отложить или открыть страницу релиза.
    private func offer(_ release: AppRelease) {
        let current = update.currentVersion.map { "\($0)" } ?? "?"
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Доступен TapLess \(release.version)"
        var text = "Сейчас установлена версия \(current)."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            text += "\n\n" + (notes.count > 1500 ? String(notes.prefix(1500)) + "…" : notes)
        }
        let inApp = release.checksumURL != nil
        if inApp {
            text += "\n\nTapLess скачает новую версию, проверит её подпись и перезапустится."
            alert.addButton(withTitle: "Обновить и перезапустить")
        } else {
            text += "\n\nУ релиза нет файла SHA-256, поэтому обновить из приложения нельзя. Скачайте его со страницы релиза."
        }
        alert.addButton(withTitle: "Позже")
        alert.addButton(withTitle: "Страница релиза")
        alert.informativeText = text
        let response = alert.runModal()
        let pageButton: NSApplication.ModalResponse = inApp ? .alertThirdButtonReturn : .alertSecondButtonReturn
        if inApp && response == .alertFirstButtonReturn {
            install(release)
        } else if response == pageButton {
            NSWorkspace.shared.open(release.pageURL)
        } else {
            Log.info("Обновления: пользователь отложил \(release.version)", .app)
        }
    }

    private func install(_ release: AppRelease) {
        guard phase == .idle else { return }
        guard canInstall() else {
            showAlert(title: "Обновление отложено",
                      text: "Дождитесь конца диктовки или правки и выберите «Обновить TapLess» в меню ещё раз.")
            return
        }
        let current = Bundle.main.bundleURL
        phase = .downloading
        Log.info("Обновления: скачиваю \(release.version) из \(release.archiveURL.absoluteString)", .app)
        let update = self.update
        job = Task { [weak self] in
            let result: Result<URL, Error>
            do {
                result = .success(try await update.prepare(release, replacing: current))
            } catch {
                result = .failure(error)
            }
            self?.finishPrepare(result, release: release, current: current)
        }
    }

    private func finishPrepare(_ result: Result<URL, Error>, release: AppRelease, current: URL) {
        phase = .idle
        job = nil
        switch result {
        case .failure(let error):
            if error is CancellationError { return }
            Log.error("Обновления: не удалось подготовить \(release.version): \(error.localizedDescription)", .app)
            failed(release, error.localizedDescription)
        case .success(let staged):
            // Пока шло скачивание, могла начаться диктовка: тогда ставим при следующем выборе в меню.
            guard canInstall() else {
                Log.info("Обновления: \(release.version) скачано, но идёт диктовка — установка отложена", .app)
                notify("TapLess \(release.version) скачан. Установить — в меню TapLess.")
                return
            }
            do {
                try update.scheduleInstall(staged: staged, replacing: current,
                                           afterExitOf: ProcessInfo.processInfo.processIdentifier)
            } catch {
                Log.error("Обновления: не удалось запустить установку: \(error.localizedDescription)", .app)
                failed(release, error.localizedDescription)
                return
            }
            Log.info("Обновления: завершаю процесс, \(release.version) поставит /bin/sh", .app)
            NSApp.terminate(nil)
        }
    }

    private func failed(_ release: AppRelease, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Не удалось обновить TapLess"
        alert.informativeText = "\(text)\n\nМожно скачать \(release.version) со страницы релиза."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Страница релиза")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
    }

    private func showAlert(title: String, text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
