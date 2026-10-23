import CryptoKit
import Foundation
import Security
import TapLessDomain

/// Ошибки обновления из GitHub Releases.
public enum UpdateError: LocalizedError, Equatable {
    case http(status: Int, message: String?)
    case rateLimited
    case invalidResponse
    case badTag(String)
    case noArchive(tag: String)
    case folderNotWritable(String)
    case checksumMissing(tag: String)
    case checksumFileInvalid
    case checksumMismatch(expected: String, actual: String)
    case adHocSigned
    case unzipFailed(String)
    case noAppInArchive
    case bundleMismatch(String)
    case signatureInvalid(String)
    case differentCertificate
    case installLaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            if let message, !message.isEmpty { return "GitHub ответил кодом \(status): \(message)" }
            return "GitHub ответил кодом \(status)"
        case .rateLimited:
            return "GitHub временно ограничил число запросов. Повторите проверку позже."
        case .invalidResponse:
            return "GitHub вернул ответ, который не удалось разобрать."
        case .badTag(let tag):
            return "Тег релиза «\(tag)» не похож на версию."
        case .noArchive(let tag):
            return "В релизе \(tag) нет TapLess.zip"
        case .folderNotWritable(let path):
            return "Нет прав на запись в папку «\(path)». Обновите TapLess вручную."
        case .checksumMissing(let tag):
            return "У релиза \(tag) нет файла контрольной суммы TapLess.zip.sha256. Обновите TapLess вручную."
        case .checksumFileInvalid:
            return "Файл контрольной суммы повреждён: ожидался SHA-256 в первом поле."
        case .checksumMismatch(let expected, let actual):
            return "Контрольная сумма не совпала (ожидалась \(expected), получена \(actual)). Обновление отменено."
        case .adHocSigned:
            return "Текущая сборка подписана ad-hoc: обновите вручную через install.sh"
        case .unzipFailed(let detail):
            return "Не удалось распаковать архив: \(detail)"
        case .noAppInArchive:
            return "В архиве нет TapLess.app."
        case .bundleMismatch(let detail):
            return "Скачанное приложение не подходит: \(detail)"
        case .signatureInvalid(let detail):
            return "Подпись новой версии не прошла проверку: \(detail)"
        case .differentCertificate:
            return "Новая версия подписана другим сертификатом, чем установленная. Обновите TapLess вручную через install.sh."
        case .installLaunchFailed(let detail):
            return "Не удалось запустить установку обновления: \(detail)"
        }
    }
}

/// Обновление из GitHub Releases: последний релиз, скачивание и проверка архива, замена `.app`.
public final class GitHubUpdater: AppUpdater {
    static let archiveName = "TapLess.zip"
    static let checksumName = "TapLess.zip.sha256"
    static let appName = "TapLess.app"
    static let stagingFolderName = ".tapless-update"

    private let repository: String
    private let apiBase: URL
    private let session: URLSession
    private let userAgent: String
    private let stagingRoot: URL?
    private let logFile: URL
    private let launchAfterInstall: Bool
    private let certificateReader: @Sendable (URL) throws -> Data?

    public convenience init(
        repository: String = "aaudin90/Tapless",
        apiBase: URL = URL(string: "https://api.github.com")!,
        session: URLSession = .shared,
        userAgent: String = "TapLess",
        stagingRoot: URL? = nil,
        logFile: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TapLess/update.log")
    ) {
        self.init(repository: repository, apiBase: apiBase, session: session, userAgent: userAgent,
                  stagingRoot: stagingRoot, logFile: logFile,
                  launchAfterInstall: true, certificateReader: GitHubUpdater.leafCertificate)
    }

    /// Полный инициализатор: тесты отключают запуск после установки и подменяют чтение сертификата.
    init(repository: String, apiBase: URL, session: URLSession, userAgent: String, stagingRoot: URL?,
         logFile: URL, launchAfterInstall: Bool, certificateReader: @escaping @Sendable (URL) throws -> Data?) {
        self.repository = repository
        self.apiBase = apiBase
        self.session = session
        self.userAgent = userAgent
        self.stagingRoot = stagingRoot
        self.logFile = logFile
        self.launchAfterInstall = launchAfterInstall
        self.certificateReader = certificateReader
    }

    // MARK: - Последний релиз

    private struct ReleaseDTO: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let body: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    public func latestRelease() async throws -> AppRelease? {
        let url = apiBase.appendingPathComponent("repos/\(repository)/releases/latest")
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        Log.info("Обновление: запрашиваю последний релиз \(repository)", .app)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidResponse }
        if http.statusCode == 404 {
            Log.info("Обновление: релизов нет", .app)
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.httpError(http, data: data)
        }
        guard let dto = try? JSONDecoder().decode(ReleaseDTO.self, from: data) else {
            throw UpdateError.invalidResponse
        }
        if dto.draft == true || dto.prerelease == true {
            Log.info("Обновление: последний релиз \(dto.tag_name) — черновик или пре-релиз, пропускаю", .app)
            return nil
        }
        guard let version = AppVersion(dto.tag_name) else { throw UpdateError.badTag(dto.tag_name) }
        guard let pageURL = URL(string: dto.html_url) else { throw UpdateError.invalidResponse }
        let assets = dto.assets ?? []
        guard let archive = assets.first(where: { $0.name == Self.archiveName }),
              let archiveURL = URL(string: archive.browser_download_url) else {
            throw UpdateError.noArchive(tag: dto.tag_name)
        }
        let checksumURL = assets.first(where: { $0.name == Self.checksumName })
            .flatMap { URL(string: $0.browser_download_url) }
        Log.info("Обновление: последний релиз \(dto.tag_name)", .app)
        return AppRelease(version: version, tag: dto.tag_name, notes: dto.body ?? "", pageURL: pageURL,
                          archiveURL: archiveURL, checksumURL: checksumURL)
    }

    private static func httpError(_ http: HTTPURLResponse, data: Data) -> UpdateError {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
        if http.statusCode == 403 || http.statusCode == 429 {
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            if remaining == "0" || http.statusCode == 429 || message?.lowercased().contains("rate limit") == true {
                return .rateLimited
            }
        }
        return .http(status: http.statusCode, message: message)
    }

    // MARK: - Подготовка

    public func prepare(_ release: AppRelease, replacing current: URL) async throws -> URL {
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.folderNotWritable(parent.path)
        }
        guard let checksumURL = release.checksumURL else { throw UpdateError.checksumMissing(tag: release.tag) }
        guard let currentCertificate = try certificateReader(current) else { throw UpdateError.adHocSigned }

        let base = stagingRoot ?? parent.appendingPathComponent(Self.stagingFolderName, isDirectory: true)
        let stagingDir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        do {
            let app = try await stage(release, checksumURL: checksumURL, current: current,
                                      currentCertificate: currentCertificate, stagingDir: stagingDir)
            Log.info("Обновление: \(release.tag) подготовлено в \(app.path)", .app)
            return app
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            if stagingRoot == nil { try? FileManager.default.removeItem(at: base) }
            if !(error is CancellationError) {
                Log.warning("Обновление: подготовка не удалась: \(error.localizedDescription)", .app)
            }
            throw error
        }
    }

    private func stage(_ release: AppRelease, checksumURL: URL, current: URL, currentCertificate: Data,
                       stagingDir: URL) async throws -> URL {
        let fileManager = FileManager.default
        Log.info("Обновление: скачиваю контрольную сумму", .app)
        let (sumData, sumResponse) = try await session.data(for: makeRequest(checksumURL, timeout: 30))
        try Self.requireSuccess(sumResponse)
        let expected = try Self.parseChecksum(String(decoding: sumData, as: UTF8.self))

        Log.info("Обновление: скачиваю архив \(release.tag)", .app)
        let (tempFile, archiveResponse) = try await session.download(for: makeRequest(release.archiveURL, timeout: 300))
        let zip = stagingDir.appendingPathComponent(Self.archiveName)
        do {
            try Self.requireSuccess(archiveResponse)
            try fileManager.moveItem(at: tempFile, to: zip)
        } catch {
            try? fileManager.removeItem(at: tempFile)
            throw error
        }
        try Task.checkCancellation()

        try Self.verifyChecksum(of: zip, expected: expected)
        Log.info("Обновление: контрольная сумма совпала", .app)

        try await Self.unzip(zip, to: stagingDir)
        try? fileManager.removeItem(at: zip)

        let app = stagingDir.appendingPathComponent(Self.appName)
        guard fileManager.fileExists(atPath: app.path) else { throw UpdateError.noAppInArchive }
        try Self.checkBundle(app, current: current, version: release.version)
        try Self.verifySignature(of: app)
        guard let newCertificate = try certificateReader(app), newCertificate == currentCertificate else {
            throw UpdateError.differentCertificate
        }
        Log.info("Обновление: подпись и сертификат проверены", .app)

        let quarantine = Process()
        quarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        quarantine.arguments = ["-dr", "com.apple.quarantine", app.path]
        quarantine.standardOutput = FileHandle.nullDevice
        quarantine.standardError = FileHandle.nullDevice
        if (try? quarantine.run()) != nil { quarantine.waitUntilExit() }
        return app
    }

    private func makeRequest(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.http(status: http.statusCode, message: nil) }
    }

    // MARK: - Контрольная сумма

    /// Первое поле первой строки — 64 hex-символа (формат `shasum -a 256`). Результат в нижнем регистре.
    static func parseChecksum(_ text: String) throws -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let field = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)?.lowercased() ?? ""
        guard field.count == 64, field.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw UpdateError.checksumFileInvalid
        }
        return field
    }

    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyChecksum(of file: URL, expected: String) throws {
        let actual = try sha256Hex(of: file)
        guard actual == expected.lowercased() else {
            throw UpdateError.checksumMismatch(expected: expected.lowercased(), actual: actual)
        }
    }

    // MARK: - Распаковка и проверки

    private static func unzip(_ zip: URL, to directory: URL) async throws {
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("tapless-ditto-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorFile)
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, directory.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let text = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
            let tail = String(text.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.unzipFailed(tail.isEmpty ? "ditto завершился с кодом \(status)" : tail)
        }
    }

    private static func infoPlist(of app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    private static func checkBundle(_ app: URL, current: URL, version: AppVersion) throws {
        guard let info = infoPlist(of: app) else { throw UpdateError.bundleMismatch("нет Info.plist") }
        let expectedID = infoPlist(of: current)?["CFBundleIdentifier"] as? String
        let newID = info["CFBundleIdentifier"] as? String
        guard let expectedID, newID == expectedID else {
            throw UpdateError.bundleMismatch("другой идентификатор (\(newID ?? "нет"), ожидался \(expectedID ?? "неизвестный"))")
        }
        let newVersion = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard newVersion == version else {
            throw UpdateError.bundleMismatch("версия в архиве \(newVersion?.description ?? "неизвестна"), ожидалась \(version)")
        }
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw UpdateError.signatureInvalid(Self.message(status))
        }
        return code
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "код \(status)"
    }

    private static func verifySignature(of app: URL) throws {
        let code = try staticCode(at: app)
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else { throw UpdateError.signatureInvalid(message(status)) }
    }

    /// Данные сертификата, которым подписан `.app` (первый в цепочке). nil — нет подписи или она ad-hoc.
    @Sendable static func leafCertificate(of app: URL) throws -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let dictionary = info as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    // MARK: - Установка

    /// Скрипт замены. Аргументы: `$1` pid, `$2` текущий `.app`, `$3` новый `.app`, `$4` запускать ли после замены.
    static let installScript = """
    pid="$1"; current="$2"; staged="$3"; launch="$4"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Обновление: жду выхода процесса $pid"
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -gt 300 ]; then
            echo "Процесс $pid не завершился за 30 с, замена отменена"
            exit 1
        fi
        sleep 0.1
    done
    old="$(dirname "$current")/.$(basename "$current").old-$pid"
    rm -rf "$old"
    if ! mv "$current" "$old"; then
        echo "Не удалось убрать старую версию $current"
        exit 1
    fi
    if ! mv "$staged" "$current"; then
        echo "Не удалось поставить новую версию, возвращаю старую"
        mv "$old" "$current"
        exit 1
    fi
    rm -rf "$old"
    stage_dir="$(dirname "$staged")"
    rm -rf "$stage_dir"
    stage_parent="$(dirname "$stage_dir")"
    if [ "$(basename "$stage_parent")" = "\(stagingFolderName)" ]; then
        rmdir "$stage_parent" 2>/dev/null
    fi
    echo "Замена выполнена"
    if [ "$launch" = "1" ]; then
        /usr/bin/open "$current"
    fi
    exit 0
    """

    public func scheduleInstall(staged: URL, replacing current: URL, afterExitOf pid: Int32) throws {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logFile.path) {
            fileManager.createFile(atPath: logFile.path, contents: nil)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.installScript, "sh", String(pid), current.path, staged.path,
                             launchAfterInstall ? "1" : "0"]
        if let handle = try? FileHandle(forWritingTo: logFile) {
            _ = try? handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
        } catch {
            throw UpdateError.installLaunchFailed(error.localizedDescription)
        }
        Log.info("Обновление: фоновая замена запущена, жду выхода процесса \(pid)", .app)
    }
}
