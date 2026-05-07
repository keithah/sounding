import Foundation
import Sparkle

@MainActor
final class SoftwareUpdateController: ObservableObject {
    @Published private(set) var statusMessage: String

    private let updaterController: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let isConfigured = Self.isConfigured(feedURL: feedURL, publicKey: publicKey)

        if isConfigured {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            statusMessage = "Automatic update checks are enabled."
        } else {
            updaterController = nil
            statusMessage = "Software updates need a Sparkle feed URL and public key before release."
        }
    }

    var canCheckForUpdates: Bool {
        updaterController != nil
    }

    func checkForUpdates() {
        guard let updaterController else {
            statusMessage = "Set SUFeedURL and SUPublicEDKey before checking for updates."
            return
        }
        updaterController.checkForUpdates(nil)
    }

    private static func isConfigured(feedURL: String?, publicKey: String?) -> Bool {
        guard
            let feedURL,
            let publicKey,
            feedURL.hasPrefix("https://"),
            !feedURL.contains("example.com"),
            !publicKey.isEmpty,
            !publicKey.contains("REPLACE_WITH")
        else {
            return false
        }
        return true
    }
}
