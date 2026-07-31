import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

#if canImport(AppIntents)
import AppIntents

@available(iOS 16.0, *)
struct AutoEnterDesktopIntent: AppIntent {
    static var title: LocalizedStringResource = "Auto Enter Desktop"
    static var description = IntentDescription("Open the app and automatically enter Desktop for a specified host.")

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Host")
    var host: String

    static var parameterSummary: some ParameterSummary {
        Summary("Enter Desktop on \(\.$host)")
    }

    func perform() async throws -> some IntentResult {
        // Persist the target host for the app to consume on launch
        UserDefaults.standard.set(host, forKey: "AutoEnterDesktopHostName")
        UserDefaults.standard.set(true, forKey: "AutoEnterTriggered")
        _ = UserDefaults.standard.synchronize()
        // Notify running app (if any) using Darwin notification
        #if canImport(CoreFoundation)
        let notifName = CFNotificationName(rawValue: "com.imneway.voidlink.autoenter" as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), notifName, nil, nil, true)
        #endif
        return .result()
    }
}

@available(iOS 16.0, *)
struct VoidLinkAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AutoEnterDesktopIntent(),
            phrases: [
                "Auto enter desktop in \(.applicationName)",
                "Open desktop on \(.applicationName)",
                "Enter desktop in \(.applicationName)"
            ],
            shortTitle: "Auto Enter Desktop",
            systemImageName: "display"
        )
    }
}

#endif
