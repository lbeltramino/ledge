import AppKit
import LedgeCore

/// Tells you when there is a newer build, and nothing else.
///
/// Deliberately not Sparkle. Sparkle installs updates, and installing an update
/// over an unsigned app that Gatekeeper already had to be talked into is worse
/// than useless — it would replace a binary the user vouched for with one they
/// did not. Until there is a Developer ID to sign with, the honest thing is to
/// say "there is a new one" and open the page.
///
/// One unauthenticated GET to GitHub's public API, at most once a day, with no
/// identifying information beyond the request itself. Switchable off in the menu.
@MainActor
final class UpdateCheck {

    static let repository = "lbeltramino/ledge"
    private static let lastCheckKey = "ledge.lastUpdateCheck"
    private static let enabledKey = "ledge.checkForUpdates"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private(set) var available: String?
    var onFound: ((String) -> Void)?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func checkIfDue(force: Bool = false) {
        guard UpdateCheck.isEnabled || force else { return }
        if !force {
            let last = UserDefaults.standard.double(forKey: UpdateCheck.lastCheckKey)
            guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: UpdateCheck.lastCheckKey)

        let url = URL(string: "https://api.github.com/repos/\(UpdateCheck.repository)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ledge/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard let self, UpdateCheckVersions.isNewer(latest, than: currentVersion) else { return }
            available = latest
            onFound?(latest)
        }
    }

    var releasesURL: URL {
        URL(string: "https://github.com/\(UpdateCheck.repository)/releases/latest")!
    }

}
