import Foundation

enum ModelState: Equatable {
    case unloaded
    case checking
    case downloading(progress: Double)
    case optimizing(progress: Double)
    case loading(progress: Double)
    case ready
    case error(String)

    var isPreparing: Bool {
        switch self {
        case .checking, .downloading, .optimizing, .loading: true
        case .unloaded, .ready, .error: false
        }
    }

    var showsSpinner: Bool {
        switch self {
        case .checking, .downloading, .optimizing, .loading: true
        default: false
        }
    }
}

enum ModelLifecycle {
    static let hubRepoPath = "models/argmaxinc/whisperkit-coreml"
    static let requiredModelNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    static func displayName(for variant: String) -> String {
        guard let first = variant.first else { return variant }
        return first.uppercased() + variant.dropFirst()
    }

    static func folderName(for variant: String) -> String {
        "openai_whisper-\(variant)"
    }

    static func modelFolder(for variant: String, modelsDirectory: URL) -> URL {
        modelsDirectory
            .appendingPathComponent(hubRepoPath)
            .appendingPathComponent(folderName(for: variant))
    }

    static func isInstalled(
        variant: String,
        modelsDirectory: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Bool {
        let folder = modelFolder(for: variant, modelsDirectory: modelsDirectory)
        return requiredModelNames.allSatisfy { name in
            fileExists(folder.appendingPathComponent("\(name).mlmodelc"))
                || fileExists(
                    folder.appendingPathComponent(
                        "\(name).mlpackage/Data/com.apple.CoreML/model.mlmodel"
                    )
                )
        }
    }

    static func shouldDownload(
        variant: String,
        modelsDirectory: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Bool {
        !isInstalled(variant: variant, modelsDirectory: modelsDirectory, fileExists: fileExists)
    }

    static func shouldReuseLoadedModel(selected: String, loaded: String?) -> Bool {
        loaded == selected
    }

    static func shouldPublish(requestID: Int, latestRequestID: Int) -> Bool {
        requestID == latestRequestID
    }

    static func recordingBlockMessage(selected: String, loaded: String?) -> String? {
        guard loaded == nil else { return nil }
        return "\(displayName(for: selected)) isn't ready yet."
    }

    static func recordingPrepareNotice(
        selected: String,
        loaded: String?,
        isPreparing: Bool
    ) -> String? {
        guard isPreparing, let loaded, loaded != selected else { return nil }
        return "Preparing \(displayName(for: selected)) - using \(displayName(for: loaded))"
    }

    /// Core ML does not report load progress. This is completed stages / total stages.
    static func percentText(from progress: Double) -> String {
        let clamped = min(max(progress, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }
}
