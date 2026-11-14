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

        // Settings (a tab of the panel, not a window)
        case sounds, notifications, autoCollapse, remove, install
        case quitApp
        case tabAbout
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

        // System notifications
        case notifPermissionNeeded, notifTaskCompleted, notifTaskFailed

        // Music (Spotify)
        case tabSessions, tabMusic
        case musicNothingPlaying, musicLyricsLoading, musicNoLyrics, musicInstrumental
        case musicSection, musicEnable, musicShowLyrics, musicShowInPill, musicNote
        case musicVolume, musicShuffle, musicRepeat, musicOpenInSpotify, musicCopied

        // Spotify account (Web API)
        case spotifyAccountSection, spotifyClientID, spotifyConnect, spotifyDisconnect
        case spotifyConnecting, spotifyConnected, spotifySignedOut, spotifyNeedsSetup
        case spotifyExpired, spotifyAccountNote
        case musicSearchPlaceholder, musicNoResults, musicSearching
        case tabLyrics, tabQueue, queuePrevious, queueNow, queueNext, queueEmpty
        case queueSignInNeeded

        // Edge dock (right-hand layout)
        case layoutSection, layoutNotch, layoutEdge, layoutNote
        case edgeRingsSection, edgeRingSessions, edgeRingsNote
        case edgeOpenPanel, edgeUsed, edgeResetsIn, edgeSessionsIdle
        case edgeSessionsWorkingOne, edgeSessionsWorkingMany

        // Sound mixer
        case tabSettings
        case geminiSessionsToggle
        case notifGeminiQuestion
        case delegatedBadge
        case delegatedHelp
        case screenLabel
        case screenAutomatic
        case screenPointer
        case eventAnimationsToggle
        case dailyTitle
        case dailyTurnsOne
        case dailyTurnsMany
        case dailyFailedOne
        case dailyFailedMany
        case usageAlertTitle
        case usageAlertBody
        case usageResetTitle
        case usageResetBody
        case usageAlertsToggle
        case hooksOutdated
        case hooksUpdate
        case tokensShort
        case tokenDetail
        case usageToday
        case usageThisWeek
        case subagentOne
        case subagentMany
        case subagentsTitle
        case activityCompacting
        case rulesSection
        case rulesEmpty
        case rulesAllUses
        case rulesLegacy
        case rulesLegacyHint
        case rulesClearAll
        case rulesRemove
        case tabMixer
        case mixerOutput, mixerInput, mixerApps, mixerNoApps, mixerAppsNote
        case mixerNoVolumeControl, mixerNoDevice, mixerMute, mixerAppFailed
        case mixerTapsOffNote, mixerSection, mixerEnableTaps, mixerTapsNote

        // File shelf
        case tabShelf
        case shelfEmptyTitle, shelfEmptyHint, shelfClear, shelfMissing
        case shelfRemove, shelfReveal, shelfCountOne, shelfCountMany
        case shelfSection, shelfEnable, shelfNote

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

    /// "12.4k" / "12,4k": token counts short enough for a badge.
    static func compact(_ n: Int, _ language: Localization.Language) -> String {
        CompactNumber.format(n, decimalComma: language == .tr)
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
        .remove: "Kaldır",
        .install: "Kur",
        .quitApp: "Claude Notch'tan çık",

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


        .notifPermissionNeeded: "İznin gerekiyor — %@",
        .notifTaskCompleted: "Görevin tamamlandı",
        .notifTaskFailed: "İşin hatayla bitti",

        .tabSessions: "Oturumlar",
        .tabMusic: "Müzik",
        .musicNothingPlaying: "Şu an bir şey çalmıyor",
        .musicLyricsLoading: "Sözler aranıyor…",
        .musicNoLyrics: "Bu parçanın sözü bulunamadı",
        .musicInstrumental: "Enstrümantal",
        .musicSection: "Müzik",
        .musicEnable: "Spotify'ı çentikte göster",
        .musicShowLyrics: "Şarkı sözlerini göster",
        .musicShowInPill: "Kapalı çentikte parçayı göster",
        .musicNote: "Spotify açıkken çentikte bir Müzik sekmesi belirir. Sözler lrclib.net'ten geliyor; popüler parçaların çoğunda var, daha niş olanlarda olmayabilir.",

        .musicVolume: "Ses",
        .musicShuffle: "Karıştır",
        .musicRepeat: "Tekrarla",
        .musicOpenInSpotify: "Spotify'da aç",
        .musicCopied: "Kopyalandı",

        .spotifyAccountSection: "Spotify hesabı",
        .spotifyClientID: "Client ID",
        .spotifyConnect: "Bağlan",
        .spotifyDisconnect: "Bağlantıyı kes",
        .spotifyConnecting: "Bağlanılıyor…",
        .spotifyConnected: "Bağlı",
        .spotifySignedOut: "Bağlı değil",
        .spotifyNeedsSetup: "Client ID gerekli",
        .spotifyExpired: "Oturum süresi doldu",
        .spotifyAccountNote: "Arama ve kuyruk için Spotify hesabı gerekiyor. developer.spotify.com'da ücretsiz bir uygulama oluştur, yönlendirme adresi olarak claudenotch://spotify-login-callback ekle ve Client ID'yi buraya yapıştır. Gizli anahtar istenmiyor; uygulama yalnızca kuyruğu ve son çalınanları okuma izni alıyor.",
        .musicSearchPlaceholder: "Şarkı ara…",
        .musicNoResults: "Sonuç yok",
        .musicSearching: "Aranıyor…",
        .tabLyrics: "Sözler",
        .tabQueue: "Kuyruk",
        .queuePrevious: "Önceki",
        .queueNow: "Şu an",
        .queueNext: "Sıradaki",
        .queueEmpty: "Kuyrukta parça yok",
        .queueSignInNeeded: "Ayarlar'dan Spotify hesabını bağla",

        .layoutSection: "Yerleşim",
        .layoutNotch: "Çentik",
        .layoutEdge: "Kenar",
        .layoutNote: "Çentik, panel ekranın üstünden sarkar. Kenar, sağ kenara yapışık dikey bir dock koyar; halkalara basınca detay baloncuğu açılır. Aynı anda yalnız biri çalışır.",
        .edgeRingsSection: "Kenar halkaları",
        .edgeRingSessions: "Oturumlar",
        .edgeRingsNote: "Dock'ta hangi halkaların görüneceğini seç. Sırayı uygulama belirler; planında olmayan bir pencere (Opus gibi) hiç gösterilmez.",
        .edgeOpenPanel: "Paneli aç",
        .edgeUsed: "kullanıldı",
        .edgeResetsIn: "%@ sonra sıfırlanır",
        .edgeSessionsIdle: "Çalışan oturum yok",
        .edgeSessionsWorkingOne: "1 oturum çalışıyor",
        .edgeSessionsWorkingMany: "%d oturum çalışıyor",

        .tabSettings: "Ayarlar",
        .geminiSessionsToggle: "Gemini oturumları",
        .notifGeminiQuestion: "Gemini bir soru soruyor",
        .delegatedBadge: "Claude'dan",
        .delegatedHelp: "Claude bu işi gemini-mcp ile Gemini'ye verdi",
        .screenLabel: "Ekran",
        .screenAutomatic: "Otomatik",
        .screenPointer: "İmlecin olduğu ekran",
        .eventAnimationsToggle: "Olay animasyonları",
        .dailyTitle: "Bugün",
        .dailyTurnsOne: "1 tur",
        .dailyTurnsMany: "%d tur",
        .dailyFailedOne: "1 hata",
        .dailyFailedMany: "%d hata",
        .usageAlertTitle: "%@ kullanımı %@",
        .usageAlertBody: "%@ sonra sıfırlanır.",
        .usageResetTitle: "%@ penceresi sıfırlandı",
        .usageResetBody: "Kullanım baştan başladı.",
        .usageAlertsToggle: "Kullanım uyarıları",
        .hooksOutdated: "Yeni olaylar eklendi, hook'ları güncelle",
        .hooksUpdate: "Güncelle",
        .tokensShort: "%@ tok",
        .tokenDetail: "giriş %@ · çıkış %@ · önbellek %@",
        .usageToday: "Bugün %@",
        .usageThisWeek: "Hafta %@",
        .subagentOne: "1 ajan",
        .subagentMany: "%d ajan",
        .subagentsTitle: "Alt ajanlar",
        .activityCompacting: "sıkıştırılıyor",
        .rulesSection: "İzin kuralları",
        .rulesEmpty: "Kayıtlı kural yok. Bir izin isteğinde \"Her zaman izin ver\"e basınca burada görünür.",
        .rulesAllUses: "tüm kullanımlar",
        .rulesLegacy: "geniş",
        .rulesLegacyHint: "Eski kural: bu kelimeyle başlayan her komuta izin verir.",
        .rulesClearAll: "Hepsini sil",
        .rulesRemove: "Kuralı sil",
        .tabMixer: "Ses",
        .mixerOutput: "Çıkış",
        .mixerInput: "Mikrofon",
        .mixerApps: "Uygulamalar",
        .mixerNoApps: "Şu an ses çalan uygulama yok",
        .mixerAppsNote: "Sesi kısılan uygulama kaynağında susturulup buradan çalınır. Sürgüyü sonuna alman sesi olduğu gibi geçirir; bu yol, uygulama susana kadar açık kalır.",
        .mixerAppFailed: "Soluk görünen uygulamanın sesi alınamadı",
        .mixerTapsOffNote: "Burada yalnızca kendi ses ayarı olan uygulamalar var. Safari, Chrome gibi uygulamalar için Ayarlar'dan uygulama sesini aç.",
        .mixerSection: "Ses karıştırıcı",
        .mixerEnableTaps: "Uygulama başına ses (deneysel)",
        .mixerTapsNote: "Açıkken, sesini kıstığın uygulama kaynağında susturulur ve sesi Claude Notch üzerinden çalınır — macOS'un uygulama başına ses için verdiği tek yol bu. Sürgüyü sonuna alırsan araya hiç girilmez. Kendi ses ayarı olan uygulamalar (Spotify, Music) bundan etkilenmez.",
        .mixerNoVolumeControl: "Bu aygıtın sesi buradan ayarlanamıyor",
        .mixerNoDevice: "Aygıt yok",
        .mixerMute: "Sustur",

        .tabShelf: "Raf",
        .shelfEmptyTitle: "Raf boş",
        .shelfEmptyHint: "Dosyaları çentiğe sürükle",
        .shelfClear: "Tümünü temizle",
        .shelfMissing: "bulunamadı",
        .shelfRemove: "Raftan çıkar",
        .shelfReveal: "Finder'da göster",
        .shelfCountOne: "1 dosya",
        .shelfCountMany: "%d dosya",
        .shelfSection: "Dosya rafı",
        .shelfEnable: "Dosya rafını göster",
        .shelfNote: "Finder'dan çentiğe sürüklediğin dosyalar rafta bekler; oradan tekrar sürükleyip başka yere bırakabilirsin. Dosyalar kopyalanmaz, yalnızca yerleri tutulur.",

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
        .remove: "Remove",
        .install: "Install",
        .quitApp: "Quit Claude Notch",

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


        .notifPermissionNeeded: "Permission needed — %@",
        .notifTaskCompleted: "Task completed",
        .notifTaskFailed: "Task ended with an error",

        .tabSessions: "Sessions",
        .tabMusic: "Music",
        .musicNothingPlaying: "Nothing playing",
        .musicLyricsLoading: "Looking for lyrics…",
        .musicNoLyrics: "No lyrics found for this track",
        .musicInstrumental: "Instrumental",
        .musicSection: "Music",
        .musicEnable: "Show Spotify in the notch",
        .musicShowLyrics: "Show lyrics",
        .musicShowInPill: "Show the track in the closed notch",
        .musicNote: "A Music tab appears while Spotify is running. Lyrics come from lrclib.net — most popular tracks are there, more obscure ones may not be.",

        .musicVolume: "Volume",
        .musicShuffle: "Shuffle",
        .musicRepeat: "Repeat",
        .musicOpenInSpotify: "Open in Spotify",
        .musicCopied: "Copied",

        .spotifyAccountSection: "Spotify account",
        .spotifyClientID: "Client ID",
        .spotifyConnect: "Connect",
        .spotifyDisconnect: "Disconnect",
        .spotifyConnecting: "Connecting…",
        .spotifyConnected: "Connected",
        .spotifySignedOut: "Not connected",
        .spotifyNeedsSetup: "Client ID required",
        .spotifyExpired: "Session expired",
        .spotifyAccountNote: "Search and the queue need a Spotify account. Create a free app at developer.spotify.com, add claudenotch://spotify-login-callback as a redirect URI, and paste the Client ID here. No client secret is involved; the app only asks to read your queue and recently played tracks.",
        .musicSearchPlaceholder: "Search tracks…",
        .musicNoResults: "No results",
        .musicSearching: "Searching…",
        .tabLyrics: "Lyrics",
        .tabQueue: "Queue",
        .queuePrevious: "Previous",
        .queueNow: "Now",
        .queueNext: "Up next",
        .queueEmpty: "Nothing queued",
        .queueSignInNeeded: "Connect your Spotify account in Settings",

        .layoutSection: "Layout",
        .layoutNotch: "Notch",
        .layoutEdge: "Edge",
        .layoutNote: "Notch hangs the panel from the top of the screen. Edge puts a vertical dock against the right-hand side; tapping a ring opens a detail bubble. Only one is active at a time.",
        .edgeRingsSection: "Edge rings",
        .edgeRingSessions: "Sessions",
        .edgeRingsNote: "Choose which rings appear in the dock. The app fixes their order, and a window your plan doesn't have (Opus, say) is never shown.",
        .edgeOpenPanel: "Open panel",
        .edgeUsed: "used",
        .edgeResetsIn: "Resets in %@",
        .edgeSessionsIdle: "Nothing working",
        .edgeSessionsWorkingOne: "1 session working",
        .edgeSessionsWorkingMany: "%d sessions working",

        .tabSettings: "Settings",
        .geminiSessionsToggle: "Gemini sessions",
        .notifGeminiQuestion: "Gemini has a question",
        .delegatedBadge: "from Claude",
        .delegatedHelp: "Claude handed this to Gemini through gemini-mcp",
        .screenLabel: "Display",
        .screenAutomatic: "Automatic",
        .screenPointer: "Follow the pointer",
        .eventAnimationsToggle: "Event animations",
        .dailyTitle: "Today",
        .dailyTurnsOne: "1 turn",
        .dailyTurnsMany: "%d turns",
        .dailyFailedOne: "1 failed",
        .dailyFailedMany: "%d failed",
        .usageAlertTitle: "%@ usage at %@",
        .usageAlertBody: "Resets in %@.",
        .usageResetTitle: "%@ window has reset",
        .usageResetBody: "Usage starts over.",
        .usageAlertsToggle: "Usage alerts",
        .hooksOutdated: "New events available — update the hooks",
        .hooksUpdate: "Update",
        .tokensShort: "%@ tok",
        .tokenDetail: "in %@ · out %@ · cache %@",
        .usageToday: "Today %@",
        .usageThisWeek: "Week %@",
        .subagentOne: "1 agent",
        .subagentMany: "%d agents",
        .subagentsTitle: "Subagents",
        .activityCompacting: "compacting",
        .rulesSection: "Permission rules",
        .rulesEmpty: "No saved rules. Choosing \"Always Allow\" on a request adds one here.",
        .rulesAllUses: "every use",
        .rulesLegacy: "broad",
        .rulesLegacyHint: "Older rule: allows every command starting with this word.",
        .rulesClearAll: "Clear all",
        .rulesRemove: "Remove rule",
        .tabMixer: "Sound",
        .mixerOutput: "Output",
        .mixerInput: "Microphone",
        .mixerApps: "Apps",
        .mixerNoApps: "Nothing is playing right now",
        .mixerAppsNote: "An app you turn down is muted at the source and replayed here. Full volume passes it through untouched; the route stays up until the app stops playing.",
        .mixerAppFailed: "The dimmed app's audio couldn't be captured",
        .mixerTapsOffNote: "Only apps with a volume of their own are listed. Turn on per-app volume in Settings to control Safari, Chrome and the rest.",
        .mixerSection: "Sound mixer",
        .mixerEnableTaps: "Per-app volume (experimental)",
        .mixerTapsNote: "When on, an app you turn down is muted at the source and its audio is played back through Claude Notch — the only route macOS offers for per-app volume. At full volume nothing is intercepted. Apps with their own volume (Spotify, Music) are unaffected.",
        .mixerNoVolumeControl: "This device's volume can't be set from here",
        .mixerNoDevice: "No device",
        .mixerMute: "Mute",

        .tabShelf: "Shelf",
        .shelfEmptyTitle: "The shelf is empty",
        .shelfEmptyHint: "Drag files onto the notch",
        .shelfClear: "Clear all",
        .shelfMissing: "missing",
        .shelfRemove: "Remove from shelf",
        .shelfReveal: "Reveal in Finder",
        .shelfCountOne: "1 file",
        .shelfCountMany: "%d files",
        .shelfSection: "File shelf",
        .shelfEnable: "Show the file shelf",
        .shelfNote: "Files dragged from Finder onto the notch wait here, and can be dragged back out to anywhere else. Nothing is copied — the shelf only remembers where each file lives.",

        .cliHooksInstalled: "Claude Notch hooks installed.",
        .cliInstallFailed: "Install failed: %@",
        .cliHooksRemoved: "Claude Notch hooks removed.",
        .cliUninstallFailed: "Uninstall failed: %@",
        .cliAlreadyRunning: "Claude Notch is already running (%@). Bringing it forward.",
    ]
}
