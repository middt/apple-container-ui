import Foundation

/// A Compose stack as it is stored between launches (runtime state such as status is not persisted).
struct PersistedStack: Codable, Equatable {
    var id: String
    var name: String
    var filePath: String
    var yamlContent: String
    var targetBackend: RuntimeBackend
    var networkName: String
}

/// User preferences persisted in `UserDefaults`.
struct AppSettings {
    private enum Key {
        static let language = "vessel.language"
        static let customBinaryPath = "vessel.customBinaryPath"
        static let stacks = "vessel.stacks"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `nil` until the user picks a language explicitly; the system language is used until then.
    var language: AppLanguage? {
        get { defaults.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: Key.language) }
    }

    var customBinaryPath: String {
        get { defaults.string(forKey: Key.customBinaryPath) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.customBinaryPath) }
    }

    var stacks: [PersistedStack] {
        get {
            guard let data = defaults.data(forKey: Key.stacks) else { return [] }
            return (try? JSONDecoder().decode([PersistedStack].self, from: data)) ?? []
        }
        nonmutating set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.stacks)
        }
    }
}
