// swift-tools-version: 5.10
// TapLess — голосовой ввод для macOS: Whisper локально + оформление текста через LLM-команду.
//
// Слои (чистая архитектура), зависимости только сверху вниз:
//   TapLess (exe)  — main (сборка зависимостей) + Presentation + Platform
//   TapLessData    — реализации репозиториев: конфиг (TOML), LLM (внешняя команда), STT (WhisperKit)
//   TapLessDomain  — модели, сценарии, протоколы репозиториев; только Foundation

import PackageDescription

let package = Package(
    name: "TapLess",
    platforms: [.macOS(.v14)],
    dependencies: [
        // WhisperKit (с версии 1.0 живёт в Argmax Open-Source SDK)
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        // Парсер TOML (обёртка над toml++)
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "TapLessDomain",
            path: "Sources/TapLessDomain"
        ),
        .target(
            name: "TapLessData",
            dependencies: [
                "TapLessDomain",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/TapLessData"
        ),
        .executableTarget(
            name: "TapLess",
            dependencies: ["TapLessDomain", "TapLessData"],
            path: "Sources/TapLess"
        ),
        .testTarget(
            name: "TapLessDomainTests",
            dependencies: ["TapLessDomain", "TapLessData"],
            path: "Tests/TapLessDomainTests"
        ),
        .testTarget(
            name: "TapLessDataTests",
            dependencies: ["TapLessDomain", "TapLessData"],
            path: "Tests/TapLessDataTests"
        ),
    ]
)
