import Foundation
import Speech
import os

/// Installation state of the on-device speech model for a given locale.
enum ModelState: Equatable, Sendable {
    case unknown
    /// Speech framework has no model for this locale at all.
    case unsupported
    /// Available to download but not on disk yet.
    case notInstalled
    /// Download in progress, 0...1.
    case downloading(Double)
    case installed
    case failed(String)

    var isReady: Bool { self == .installed }
}

/// Owns discovery, download and retention of `SpeechTranscriber` assets.
///
/// Everything here is on-device. `AssetInventory` downloads from Apple's model
/// CDN the first time a locale is used, then never touches the network again.
enum ModelCatalog {

    /// Locales the installed OS can transcribe, sorted for display.
    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted {
            ($0.identifier(.bcp47)) < ($1.identifier(.bcp47))
        }
    }

    /// Maps an arbitrary locale onto the closest one the framework supports,
    /// e.g. `en_GB_POSIX` → `en-GB`. Returns nil when nothing matches.
    static func resolve(_ locale: Locale) async -> Locale? {
        // Exact BCP-47 match first.
        let wanted = locale.identifier(.bcp47)
        if await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == wanted }) {
            return locale
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Mirrors exactly the configuration `SpeechEngine` builds, so status and
    /// installation are asked about the module that will actually run.
    private static func probe(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    static func state(for locale: Locale) async -> ModelState {
        guard SpeechTranscriber.isAvailable else { return .unsupported }
        guard let resolved = await resolve(locale) else { return .unsupported }

        // `installedLocales` is checked first: on a client's very first call,
        // `AssetInventory.status` reports `.supported` for an already-installed
        // locale and only flips to `.installed` after an installation request
        // has been made once. Trusting it alone shows a spurious "Downloading…"
        // on first launch, during which dictation refuses to start.
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }) {
            return .installed
        }

        switch await AssetInventory.status(forModules: [probe(for: resolved)]) {
        case .unsupported:  return .unsupported
        case .supported:    return .notInstalled
        case .downloading:  return .downloading(0)
        case .installed:    return .installed
        @unknown default:   return .unknown
        }
    }

    /// Downloads and installs the model if needed, reporting progress.
    ///
    /// Also *reserves* the locale afterwards. Without a reservation the system
    /// is free to evict the model to reclaim disk, which would turn a later
    /// dictation into a surprise multi-hundred-megabyte download.
    static func install(
        locale: Locale,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let resolved = await resolve(locale) else {
            throw ModelCatalogError.unsupportedLocale(locale.identifier(.bcp47))
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe(for: resolved)]) {
            let progress = request.progress

            // Poll rather than KVO: Progress KVO delivers on arbitrary queues
            // and this is a once-per-locale operation where 10 Hz is plenty.
            let reporter = Task {
                while !Task.isCancelled {
                    onProgress(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { reporter.cancel() }

            Log.speech.info("Downloading speech model for \(resolved.identifier(.bcp47), privacy: .public)")
            try await request.downloadAndInstall()
            onProgress(1.0)
        }

        await reserve(resolved)
    }

    /// Reserves `locale`, releasing whatever we reserved previously.
    ///
    /// `AssetInventory.maximumReservedLocales` is 5. Without releasing, changing
    /// language six times exhausts every slot, `reserve` starts failing, and the
    /// *active* model becomes evictable again — precisely the surprise
    /// multi-hundred-megabyte download reserving was meant to prevent.
    private static func reserve(_ locale: Locale) async {
        let previous = reservedLocale.withLock { held -> Locale? in
            let old = held
            held = locale
            return old
        }

        if let previous, previous != locale {
            _ = await AssetInventory.release(reservedLocale: previous)
        }

        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            // Not fatal: it only means the model may be evicted later.
            Log.speech.warning("Could not reserve locale: \(error.localizedDescription)")
            reservedLocale.withLock { $0 = nil }
        }
    }

    /// The one locale we currently hold a reservation for.
    private static let reservedLocale = OSAllocatedUnfairLock<Locale?>(initialState: nil)
}

enum ModelCatalogError: LocalizedError {
    case unsupportedLocale(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id):
            return "This Mac has no on-device speech model for \(id)."
        }
    }
}
