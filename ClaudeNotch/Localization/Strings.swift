import Foundation

/// Every translatable string in the app, keyed by an enum so call sites are checked at
/// compile time and a typo can't silently render an empty label.
///
/// What is *not* in here, on purpose:
/// - Strings Claude reads rather than the user (`PermissionPolicy.reply` reasons,
///   `QuestionParser.reply`) — translating those degrades the model's behaviour.
/// - Protocol and matching data: usage `severity`, tool names, `PermissionDecision`
///   raw values (the CLI wire format), `PromptText` prefixes, `LogViewer`'s tinting
///   keywords, AppleScript sources, macOS system sound names.
/// - Proper nouns: Claude, Opus/Sonnet/Haiku/Fable, terminal app names, "Claude Notch".
/// - Developer output (`fputs(…, stderr)`) and `MockData`.
enum L10n {

    enum Key: String, CaseIterable {
        // Aggregate status word. Shared by the closed pill and the panel header — it
        // flies between them via matchedGeometryEffect, so it must be one string, and
        // the pill is narrow: keep these terse in both languages.
        case statusPermission, statusQuestion, statusWorking, statusWaiting
        case statusError, statusIdle

        // ActivityKind.verb
        case activityEditing, activityRunningTests, activityRunning, activityPlanning
        case activitySearching, activityReading, activityWaiting, activityIdle

        // Usage windows and credits
        case usageFiveHour, usageWeekly
        case usageFiveHourLong, usageWeeklyLong, usageOpusLong
        case usageLocal, usageSignIn, usageExtraCredits
        case sessionCountShort

        // Duration unit suffixes, used to build countdowns and elapsed times
        case unitDay, unitHour, unitMinute, unitSecond

        // Session row
        case permissionNeeded, questionWaiting, taskCompletedShort, tapToOpen, youSaid

        // Empty state
        case emptyTitle, emptyHint

        // Permission
        case deny, allowOnce, alwaysAllow
        case riskLow, riskMedium, riskHigh
        case permTitleRunCommand, permTitleEdit, permTitleWriteFile
        case permTitleEditNotebook, permTitleFetchURL, permTitleMCPTool

        // Question
        case questionTitle, optionFallback

        // Completion
        case taskCompleted, errorTitle, openTerminal, dismiss
        case testsPassing, testsFailing, turnEndedWithError

        // Focused session
        case done, tabConversation, tabLog, promptPlaceholder
        case showAllSessionsOne, showAllSessionsMany
        case noConversation, thisTerminal, terminalNoScriptedInput, terminalUnreachable
        case searchLog, youPrefix

        // Quick settings
        case sounds, notifications, autoCollapse, hooks, remove, install
        case allSettings, quitApp

        // Settings window
        case tabGeneral, tabAbout
        case sectionStartup, launchAtLogin
        case sectionNotch, autoCollapseWhenIdle, compactMode, accentColor, accentNote
        case accentGreen, accentBlue, accentViolet, accentAmber, accentRed
        case sectionAlerts
        case sectionNotchInteraction, answerPermissionsInNotch, answerQuestionsInNotch
        case interceptNote
        case sectionIntegration, observerHooks, installed, notInstalled, hooksNote
        case hooksPointElsewhere, hooksPointMissing, pointAtThisCopy
        case sectionLanguage
        case aboutTagline, sessionsObservedOne, sessionsObservedMany
        case signedBy, signedByNobody

        // Menu bar
        case openNotch, hooksInstalledMenu, hooksNotInstalledMenu, settingsMenu
        case workingCountOne, workingCountMany

        // System notifications
        case notifPermissionNeeded, notifTaskCompleted, notifTaskFailed

        // CLI messages a user can actually trigger
        case cliHooksInstalled, cliInstallFailed, cliHooksRemoved, cliUninstallFailed
        case cliAlreadyRunning
    }

    /// Resolution order: requested language, then English, then the key name. The last
    /// step means a missing translation shows something debuggable instead of a blank.
    static func string(_ key: Key, _ language: Localization.Language) -> String {
        table(language)[key] ?? en[key] ?? key.rawValue
    }

    static func table(_ language: Localization.Language) -> [Key: String] {
        switch language {
        case .tr: return tr
        case .en: return en
        }
    }

    /// Turkish writes the percent sign before the number ("%15"), English after ("15%").
    static func percent(_ value: Int, _ language: Localization.Language) -> String {
        language == .tr ? "%\(value)" : "\(value)%"
    }

    /// Turkish uses a comma as the decimal separator.
    static func decimal(_ value: Double, _ language: Localization.Language) -> String {
        if value == value.rounded() { return String(Int(value)) }
        let s = String(format: "%.2f", value)
        return language == .tr ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    // MARK: - Türkçe
    //
    // Ton: samimi ("sen"). Cümleler, ayarlar ve bildirimler kullanıcıya doğrudan hitap
    // eder. Tek istisna durum kelimeleri ve rozetler — çentik dar, orada kısa kalıyoruz.

    static let tr: [Key: String] = [
        .statusPermission: "İzin…",
        .statusQuestion: "Soru…",
        .statusWorking: "Çalışıyor…",
        .statusWaiting: "Bekliyor…",
        .statusError: "Hata",
        .statusIdle: "Boşta",

        .activityEditing: "Düzenliyor",
        .activityRunningTests: "Test çalıştırıyor",
        .activityRunning: "Çalıştırıyor",
        .activityPlanning: "Planlıyor",
        .activitySearching: "Arıyor",
        .activityReading: "Okuyor",
        .activityWaiting: "Bekliyor",
        .activityIdle: "Boşta",

        .usageFiveHour: "5sa",
        .usageWeekly: "7g",
        .usageFiveHourLong: "5 saat",
        .usageWeeklyLong: "7 gün",
        .usageOpusLong: "Opus 7 gün",
        .usageLocal: "yerel sayım",
        .usageSignIn: "Canlı limitlerini görmek için Claude Code'a giriş yap",
        .usageExtraCredits: "ek kredi",
        .sessionCountShort: "%d oturum",

        .unitDay: "g",
        .unitHour: "sa",
        .unitMinute: "dk",
        .unitSecond: "sn",

        .permissionNeeded: "İznin gerekiyor",
        .questionWaiting: "Sana bir soru var",
        .taskCompletedShort: "Görevin tamamlandı",
        .tapToOpen: "açmak için dokun",
        .youSaid: "Sen: %@",

        .emptyTitle: "Açık bir Claude Code oturumun yok",
        .emptyHint: "Bir terminalde `claude` başlat, burada belirsin",

        .deny: "Reddet",
        .allowOnce: "Bir kez izin ver",
        .alwaysAllow: "Hep izin ver",
        .riskLow: "Düşük",
        .riskMedium: "Orta",
        .riskHigh: "Yüksek",
        .permTitleRunCommand: "Komut çalıştır",
        .permTitleEdit: "Düzenle",
        .permTitleWriteFile: "Dosya yaz",
        .permTitleEditNotebook: "Notebook düzenle",
        .permTitleFetchURL: "URL getir",
        .permTitleMCPTool: "MCP aracı",

        .questionTitle: "Claude'un sorusu",
        .optionFallback: "Seçenek %d",

        .taskCompleted: "Görevin tamamlandı",
        .errorTitle: "Hata",
        .openTerminal: "Terminali aç",
        .dismiss: "Kapat",
        .testsPassing: "testler geçiyor",
        .testsFailing: "testler geçmiyor",
        .turnEndedWithError: "İşlem hatayla bitti.",

        .done: "Bitti",
        .tabConversation: "Konuşma",
        .tabLog: "Günlük",
        .promptPlaceholder: "Bu oturuma bir şeyler yaz…",
        .showAllSessionsOne: "Tek oturumu göster",
        .showAllSessionsMany: "%d oturumun tümünü göster",
        .noConversation: "Henüz konuşma yok",
        .thisTerminal: "Bu terminal",
        .terminalNoScriptedInput: "%@ dışarıdan yazmaya izin vermiyor — mesajını kopyaladım, yapıştırman yeterli.",
        .terminalUnreachable: "Terminale ulaşamadım.",
        .searchLog: "Günlükte ara",
        .youPrefix: "Sen:",

        .sounds: "Sesler",
        .notifications: "Bildirimler",
        .autoCollapse: "Kendiliğinden kapan",
        .hooks: "Hook'lar",
        .remove: "Kaldır",
        .install: "Kur",
        .allSettings: "Tüm ayarlar…",
        .quitApp: "Claude Notch'tan çık",

        .tabGeneral: "Genel",
        .tabAbout: "Hakkında",
        .sectionStartup: "Başlangıç",
        .launchAtLogin: "Açılışta beni başlat",
        .sectionNotch: "Çentik",
        .autoCollapseWhenIdle: "Boştayken kendiliğinden kapan",
        .compactMode: "Sıkışık görünüm",
        .accentColor: "Vurgu rengi",
        .accentNote: "Yalnız vurgulara uygulanır — çalışıyor / bekliyor / hata renkleri sabit kalır ki durumu bir bakışta okuyabilesin.",
        .accentGreen: "Yeşil",
        .accentBlue: "Mavi",
        .accentViolet: "Mor",
        .accentAmber: "Kehribar",
        .accentRed: "Kırmızı",
        .sectionAlerts: "Uyarılar",
        .sectionNotchInteraction: "Çentik etkileşimi",
        .answerPermissionsInNotch: "İzinleri çentikte yanıtla",
        .answerQuestionsInNotch: "Soruları çentikte yanıtla",
        .interceptNote: "Açıkken izin istekleri ve Claude'un soruları (varsayılan izin modunda) terminal yerine çentikte karşına gelir.",
        .sectionIntegration: "Claude Code entegrasyonu",
        .observerHooks: "Gözlemci hook'ları",
        .installed: "Kurulu",
        .notInstalled: "Kurulu değil",
        .hooksNote: "~/.claude/settings.json dosyana gözlemci hook'ları ekler, böylece çentik Claude Code oturumlarını görebilir. Diğer ayarların olduğu gibi kalır; kaldırman da güvenli.",
        .hooksPointElsewhere: "Hook'ların başka bir kopyayı gösteriyor",
        .hooksPointMissing: "Hook'ların artık var olmayan bir dosyayı gösteriyor",
        .pointAtThisCopy: "Hook'ları buraya bağla",
        .sectionLanguage: "Dil",
        .aboutTagline: "Çentikte yaşayan, Claude Code için yerel bir yardımcı.",
        .sessionsObservedOne: "1 oturum izlendi",
        .sessionsObservedMany: "%d oturum izlendi",
        .signedBy: "%@ · imzalayan: %@",
        .signedByNobody: "kimse",

        .openNotch: "Çentiği aç",
        .hooksInstalledMenu: "Hook'lar: kurulu",
        .hooksNotInstalledMenu: "Hook'lar: kurulu değil",
        .settingsMenu: "Ayarlar…",
        .workingCountOne: "1 oturum çalışıyor",
        .workingCountMany: "%d oturum çalışıyor",

        .notifPermissionNeeded: "İznin gerekiyor — %@",
        .notifTaskCompleted: "Görevin tamamlandı",
        .notifTaskFailed: "İşin hatayla bitti",

        .cliHooksInstalled: "Claude Notch hook'ları kuruldu.",
        .cliInstallFailed: "Kurulum başarısız: %@",
        .cliHooksRemoved: "Claude Notch hook'ları kaldırıldı.",
        .cliUninstallFailed: "Kaldırma başarısız: %@",
        .cliAlreadyRunning: "Claude Notch zaten çalışıyor (%@). Öne getiriliyor.",
    ]

    // MARK: - English

    static let en: [Key: String] = [
        .statusPermission: "Permission…",
        .statusQuestion: "Question…",
        .statusWorking: "Working…",
        .statusWaiting: "Waiting…",
        .statusError: "Error",
        .statusIdle: "Idle",

        .activityEditing: "Editing",
        .activityRunningTests: "Running tests",
        .activityRunning: "Running",
        .activityPlanning: "Planning",
        .activitySearching: "Searching",
        .activityReading: "Reading",
        .activityWaiting: "Waiting",
        .activityIdle: "Idle",

        .usageFiveHour: "5h",
        .usageWeekly: "7d",
        .usageFiveHourLong: "5-hour",
        .usageWeeklyLong: "7-day",
        .usageOpusLong: "Opus 7-day",
        .usageLocal: "local usage",
        .usageSignIn: "Sign in to Claude Code to see live limits",
        .usageExtraCredits: "extra credits",
        .sessionCountShort: "%d sess",

        .unitDay: "d",
        .unitHour: "h",
        .unitMinute: "m",
        .unitSecond: "s",

        .permissionNeeded: "Permission needed",
        .questionWaiting: "Question waiting",
        .taskCompletedShort: "Task completed",
        .tapToOpen: "tap to open",
        .youSaid: "You: %@",

        .emptyTitle: "No active Claude Code sessions",
        .emptyHint: "Start `claude` in a terminal to see it here",

        .deny: "Deny",
        .allowOnce: "Allow Once",
        .alwaysAllow: "Always Allow",
        .riskLow: "Low",
        .riskMedium: "Medium",
        .riskHigh: "High",
        .permTitleRunCommand: "Run command",
        .permTitleEdit: "Edit",
        .permTitleWriteFile: "Write file",
        .permTitleEditNotebook: "Edit notebook",
        .permTitleFetchURL: "Fetch URL",
        .permTitleMCPTool: "MCP tool",

        .questionTitle: "Claude's Question",
        .optionFallback: "Option %d",

        .taskCompleted: "Task Completed",
        .errorTitle: "Error",
        .openTerminal: "Open Terminal",
        .dismiss: "Dismiss",
        .testsPassing: "tests passing",
        .testsFailing: "tests failing",
        .turnEndedWithError: "The turn ended with an error.",

        .done: "Done",
        .tabConversation: "Conversation",
        .tabLog: "Log",
        .promptPlaceholder: "Send a prompt to this session…",
        .showAllSessionsOne: "Show the only session",
        .showAllSessionsMany: "Show all %d sessions",
        .noConversation: "No conversation yet",
        .thisTerminal: "This terminal",
        .terminalNoScriptedInput: "%@ doesn't support scripted input — prompt copied, paste it in.",
        .terminalUnreachable: "Couldn't reach the terminal.",
        .searchLog: "Search log",
        .youPrefix: "You:",

        .sounds: "Sounds",
        .notifications: "Notifications",
        .autoCollapse: "Auto-collapse",
        .hooks: "Hooks",
        .remove: "Remove",
        .install: "Install",
        .allSettings: "All Settings…",
        .quitApp: "Quit Claude Notch",

        .tabGeneral: "General",
        .tabAbout: "About",
        .sectionStartup: "Startup",
        .launchAtLogin: "Launch at login",
        .sectionNotch: "Notch",
        .autoCollapseWhenIdle: "Auto-collapse when idle",
        .compactMode: "Compact mode",
        .accentColor: "Accent color",
        .accentNote: "Applies to accents only — working / waiting / error keep their colors so status stays readable.",
        .accentGreen: "Green",
        .accentBlue: "Blue",
        .accentViolet: "Violet",
        .accentAmber: "Amber",
        .accentRed: "Red",
        .sectionAlerts: "Alerts",
        .sectionNotchInteraction: "Notch interaction",
        .answerPermissionsInNotch: "Answer permissions in notch",
        .answerQuestionsInNotch: "Answer questions in notch",
        .interceptNote: "When on, permission prompts and Claude's questions (in default permission mode) are handled in the notch instead of the terminal.",
        .sectionIntegration: "Claude Code integration",
        .observerHooks: "Observer hooks",
        .installed: "Installed",
        .notInstalled: "Not installed",
        .hooksNote: "Adds observer hooks to ~/.claude/settings.json so the notch can see your Claude Code sessions. Your other settings are preserved; removing is safe.",
        .hooksPointElsewhere: "Hooks point at a different copy",
        .hooksPointMissing: "Hooks point at a binary that no longer exists",
        .pointAtThisCopy: "Point them at this copy",
        .sectionLanguage: "Language",
        .aboutTagline: "A native companion for Claude Code that lives in the notch.",
        .sessionsObservedOne: "1 session observed",
        .sessionsObservedMany: "%d sessions observed",
        .signedBy: "%@ · signed by %@",
        .signedByNobody: "nobody",

        .openNotch: "Open Notch",
        .hooksInstalledMenu: "Hooks: installed",
        .hooksNotInstalledMenu: "Hooks: not installed",
        .settingsMenu: "Settings…",
        .workingCountOne: "1 session working",
        .workingCountMany: "%d sessions working",

        .notifPermissionNeeded: "Permission needed — %@",
        .notifTaskCompleted: "Task completed",
        .notifTaskFailed: "Task ended with an error",

        .cliHooksInstalled: "Claude Notch hooks installed.",
        .cliInstallFailed: "Install failed: %@",
        .cliHooksRemoved: "Claude Notch hooks removed.",
        .cliUninstallFailed: "Uninstall failed: %@",
        .cliAlreadyRunning: "Claude Notch is already running (%@). Bringing it forward.",
    ]
}
