import Foundation

/// An app whose copies Stacks2 treats as concealed. Kept with its name, so an
/// app that isn't installed still shows by name in the settings.
struct PasswordApp: Codable, Equatable {
    var id: String
    var name: String
}

/// Password apps: what's copied while one of them is in front is handled as
/// a concealed copy, marked or not. Apple's Passwords never marks its copies.
/// The list is saved in the settings once it's changed in the panel.
@MainActor
enum PasswordApps {
    static let defaults: [PasswordApp] = [
        PasswordApp(id: "com.apple.Passwords", name: "Passwords"),
        PasswordApp(id: "com.apple.keychainaccess", name: "Keychain Access"),
        PasswordApp(id: "com.app77.pwsafemac", name: "pwSafe"),
        PasswordApp(id: "com.1password.1password", name: "1Password"),
        PasswordApp(id: "com.agilebits.onepassword7", name: "1Password 7"),
        PasswordApp(id: "com.bitwarden.desktop", name: "Bitwarden"),
        PasswordApp(id: "org.keepassxc.keepassxc", name: "KeePassXC"),
        PasswordApp(id: "com.authy.authy-mac", name: "Authy"),
    ]

    private static let defaultsKey = "passwordApps"

    private(set) static var list: [PasswordApp] = load()

    static func contains(_ bundleID: String) -> Bool {
        list.contains { $0.id == bundleID }
    }

    static func set(_ apps: [PasswordApp]) {
        list = apps
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static var json: String { encode(list) }
    static var defaultsJSON: String { encode(defaults) }

    private static func encode(_ apps: [PasswordApp]) -> String {
        guard let data = try? JSONEncoder().encode(apps) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func load() -> [PasswordApp] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([PasswordApp].self, from: data) else {
            return defaults
        }
        return saved
    }
}
