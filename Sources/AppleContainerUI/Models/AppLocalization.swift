import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case en = "en"
    case tr = "tr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .en: return "English"
        case .tr: return "Türkçe"
        }
    }

    var shortCode: String {
        switch self {
        case .en: return "EN"
        case .tr: return "TR"
        }
    }

    /// Detects the preferred language from the computer's macOS locale settings.
    /// Selects Turkish (`.tr`) if the system language is Turkish; defaults to English (`.en`) for any other or unsupported language.
    static func detectSystemDefault() -> AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? Locale.current.identifier.lowercased()
        if preferred.hasPrefix("tr") {
            return .tr
        }
        return .en
    }
}

extension SidebarItem {
    func title(in lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.dashboard, .en): return "Dashboard"
        case (.dashboard, .tr): return "Panel"
        case (.containers, .en): return "Containers"
        case (.containers, .tr): return "Konteynerler"
        case (.stacks, .en): return "Compose Stacks"
        case (.stacks, .tr): return "Compose Yığınları"
        case (.images, .en): return "Images"
        case (.images, .tr): return "İmajlar"
        case (.volumes, .en): return "Volumes"
        case (.volumes, .tr): return "Disk Bölümleri"
        case (.networks, .en): return "Networks"
        case (.networks, .tr): return "Ağlar (vmnet)"
        case (.activity, .en): return "CLI & Settings"
        case (.activity, .tr): return "CLI & Ayarlar"
        }
    }

    func localizedSubtitle(in lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.dashboard, .en): return "Cluster & Charts"
        case (.dashboard, .tr): return "Küme & Grafikler"
        case (.containers, .en): return "Linux MicroVMs"
        case (.containers, .tr): return "Linux MicroVM'ler"
        case (.stacks, .en): return "docker-compose.yml"
        case (.stacks, .tr): return "docker-compose.yml"
        case (.images, .en): return "OCI Registry & Layers"
        case (.images, .tr): return "OCI Kayıt & Katmanlar"
        case (.volumes, .en): return "Persistent Storage"
        case (.volumes, .tr): return "Kalıcı Depolama"
        case (.networks, .en): return "vmnet Bridges & DNS"
        case (.networks, .tr): return "vmnet Köprü & DNS"
        case (.activity, .en): return "Engine & Command Log"
        case (.activity, .tr): return "Motor & Komut Günlüğü"
        }
    }
}

extension ContainerDetailTab {
    func title(in lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.stats, .en): return "Metrics"
        case (.stats, .tr): return "Metrikler"
        case (.logs, .en): return "Logs"
        case (.logs, .tr): return "Loglar"
        case (.terminal, .en): return "Exec / Shell"
        case (.terminal, .tr): return "Komut / Kabuk"
        case (.info, .en): return "Inspect & Mounts"
        case (.info, .tr): return "Detay & Diskler"
        case (.files, .en): return "Files"
        case (.files, .tr): return "Dosyalar"
        case (.rawJSON, .en): return "Raw JSON"
        case (.rawJSON, .tr): return "Ham JSON"
        }
    }
}

extension ContainerFilterState {
    func title(in lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.all, .en): return "All"
        case (.all, .tr): return "Tümü"
        case (.running, .en): return "Running"
        case (.running, .tr): return "Çalışan"
        case (.stopped, .en): return "Stopped"
        case (.stopped, .tr): return "Durmuş"
        }
    }
}

extension ContainerState {
    func localizedLabel(in lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.running, .en): return "Running"
        case (.running, .tr): return "Çalışıyor"
        case (.stopped, .en): return "Stopped"
        case (.stopped, .tr): return "Durduruldu"
        case (.paused, .en): return "Paused"
        case (.paused, .tr): return "Duraklatıldı"
        case (.starting, .en): return "Starting…"
        case (.starting, .tr): return "Başlatılıyor…"
        case (.stopping, .en): return "Stopping…"
        case (.stopping, .tr): return "Durduruluyor…"
        }
    }
}

extension ComposeStackTab {
    func title(in lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.topology, .en): return "Services & Topology"
        case (.topology, .tr): return "Servisler & Topoloji"
        case (.yaml, .en): return "docker-compose.yml"
        case (.yaml, .tr): return "docker-compose.yml"
        case (.plan, .en): return "Apple Container Execution"
        case (.plan, .tr): return "Apple Container Planı"
        case (.logs, .en): return "Stack Logs"
        case (.logs, .tr): return "Yığın Logları"
        }
    }
}

