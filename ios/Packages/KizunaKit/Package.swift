// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KizunaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(
            name: "KizunaKit",
            targets: [
                "CoreModels", "LearnerModel", "ContentKit", "SpeechKit",
                "RealtimeKit", "ModeEngine", "Modes", "LanguagePackCore", "JapanesePack",
                "Persistence", "SyncKit", "DesignSystem",
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Value types shared by everything: ContentItem, ReviewEvent, ErrorEvent,
        // provider request/response types, ChatProvider (§4.3.2).
        .target(name: "CoreModels"),

        // LanguagePack protocol + shared language types (§5).
        .target(name: "LanguagePackCore", dependencies: ["CoreModels"]),

        // Japanese reference pack: tokenizer, furigana, pitch, registers (§5).
        .target(name: "JapanesePack", dependencies: ["LanguagePackCore"]),

        // GRDB setup, migrations (§4.7), record types.
        .target(name: "Persistence", dependencies: [
            "CoreModels",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),

        // FSRS engine, mastery queries, error ingestion (§4.5).
        .target(name: "LearnerModel", dependencies: ["CoreModels", "Persistence"]),

        // Curriculum store, scenario templates, dictionary access.
        .target(name: "ContentKit", dependencies: ["CoreModels", "Persistence", "LanguagePackCore"]),

        // STT/TTS/pronunciation interfaces + Apple on-device impls (§4.3.2).
        .target(name: "SpeechKit", dependencies: ["CoreModels", "LanguagePackCore"]),

        // WSS client for realtime voice via proxy (§4.3.2 RealtimeVoiceProvider).
        .target(name: "RealtimeKit", dependencies: ["CoreModels"]),

        // LearningMode protocol + registry + SessionRunner (§4.6).
        .target(name: "ModeEngine", dependencies: [
            "CoreModels", "LearnerModel", "ContentKit", "SpeechKit",
            "RealtimeKit", "LanguagePackCore", "Persistence", "SyncKit",
        ]),

        // The learning modes (§4.6 launch set). Each mode is a plugin registered
        // in the ModeRegistry; zero changes to core to add one.
        .target(name: "Modes", dependencies: [
            "ModeEngine", "CoreModels", "ContentKit", "SpeechKit",
            "LearnerModel", "LanguagePackCore",
        ]),

        // Supabase sync (§4.7 sync rules).
        .target(name: "SyncKit", dependencies: ["CoreModels", "Persistence"]),

        // Shared UI primitives (PromptCard, AnswerBar, PitchContourView…).
        .target(name: "DesignSystem"),

        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "CoreModels"]),
        .testTarget(name: "JapanesePackTests", dependencies: ["JapanesePack"]),
        .testTarget(name: "LearnerModelTests", dependencies: ["LearnerModel", "CoreModels", "Persistence"]),
        .testTarget(name: "SpeechKitTests", dependencies: ["SpeechKit", "CoreModels", "JapanesePack"]),
        .testTarget(name: "ContentKitTests", dependencies: ["ContentKit", "CoreModels", "Persistence"]),
        .testTarget(name: "ModeEngineTests", dependencies: [
            "ModeEngine", "Modes", "CoreModels", "Persistence", "JapanesePack", "ContentKit", "SyncKit",
        ]),
        .testTarget(name: "SyncKitTests", dependencies: ["SyncKit", "CoreModels", "Persistence"]),
    ]
)
