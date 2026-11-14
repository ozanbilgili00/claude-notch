import Foundation
import Security

/// Who exactly is running: which binary, which version, signed by whom. The notch is
/// invisible by design, so when something misbehaves the first question is always
/// "which copy am I even looking at" — this answers it in Settings and in the logs.
enum AppInfo {

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    }

    /// The `.app` bundle path, or the raw executable path when running unbundled.
    static var bundlePath: String {
        Bundle.main.bundlePath
    }

    /// Sent on every outbound HTTP request. LRCLIB asks clients to identify themselves and
    /// Spotify logs it; one definition so the two can't drift.
    static var userAgent: String {
        "ClaudeNotch/\(version) (https://github.com/ozanbilgili00/claude-notch)"
    }

    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// True when this copy lives in /Applications rather than a build directory.
    static var isInstalledCopy: Bool {
        executablePath.hasPrefix("/Applications/")
    }

    /// Where this copy came from, in a form worth showing a human.
    static var originLabel: String {
        if isInstalledCopy { return "/Applications" }
        if executablePath.contains("/DerivedData/") { return "Xcode build" }
        return (bundlePath as NSString).deletingLastPathComponent
    }

    /// Common name of the signing certificate, "ad-hoc" for an ad-hoc signature, or nil
    /// when the copy is unsigned. A *stable* authority is what keeps macOS from treating
    /// each rebuild as a brand-new app and re-asking for notification/automation access.
    static var signingAuthority: String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }

        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certs.first {
            var name: CFString?
            if SecCertificateCopyCommonName(leaf, &name) == errSecSuccess,
               let name = name as String? {
                return name
            }
        }

        // kSecCodeSignatureAdhoc (CSCommon.h) — an ad-hoc signature carries no cert chain.
        if let signFlags = dict[kSecCodeInfoFlags as String] as? UInt32,
           signFlags & 0x0002 != 0 {
            return "ad-hoc"
        }
        return nil
    }
}
