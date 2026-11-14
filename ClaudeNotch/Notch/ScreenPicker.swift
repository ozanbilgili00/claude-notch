import AppKit

/// Which display the notch or the edge dock lives on.
enum ScreenChoice: Equatable {
    /// The notched built-in display in notch mode, the menu-bar display in edge mode.
    case automatic
    /// Whichever display the pointer is on; the window follows it across while idle.
    case pointer
    /// One display, by its CoreGraphics id. Falls back to automatic while unplugged.
    case display(UInt32)

    static let key = "screenChoice"

    init(raw: String?) {
        switch raw {
        case "pointer": self = .pointer
        case let r? where r.hasPrefix("id:"): self = UInt32(r.dropFirst(3)).map(ScreenChoice.display) ?? .automatic
        default: self = .automatic
        }
    }

    var raw: String {
        switch self {
        case .automatic:        return "auto"
        case .pointer:          return "pointer"
        case .display(let id):  return "id:\(id)"
        }
    }

    static var stored: ScreenChoice { ScreenChoice(raw: UserDefaults.standard.string(forKey: key)) }
}

/// What the picker needs to know about a display, so the choice itself is testable
/// without real screens.
struct ScreenCandidate: Equatable {
    var id: UInt32
    var frame: CGRect
    var hasNotch: Bool
    /// AppKit puts the menu-bar display at the origin.
    var isMenuBar: Bool { frame.origin == .zero }
}

enum ScreenPicker {
    static func pick(_ choice: ScreenChoice, mode: DockMode, candidates: [ScreenCandidate],
                     pointer: CGPoint) -> UInt32? {
        switch choice {
        case .display(let id) where candidates.contains(where: { $0.id == id }):
            return id
        case .pointer:
            if let under = candidates.first(where: { $0.frame.contains(pointer) }) { return under.id }
        default:
            break
        }
        // Automatic: a real notch is the whole point of notch mode; the dock wants the
        // display with the menu bar, which is where the rest of the system's chrome is.
        if mode == .notch, let notched = candidates.first(where: \.hasNotch) { return notched.id }
        return (candidates.first(where: \.isMenuBar) ?? candidates.first)?.id
    }

    // MARK: Live screens

    static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func candidates() -> [ScreenCandidate] {
        NSScreen.screens.map {
            ScreenCandidate(id: displayID($0), frame: $0.frame, hasNotch: $0.safeAreaInsets.top > 0)
        }
    }

    /// The screen to build on right now for this layout.
    static func screen(for mode: DockMode, choice: ScreenChoice = .stored) -> NSScreen {
        let id = pick(choice, mode: mode, candidates: candidates(), pointer: NSEvent.mouseLocation)
        return NSScreen.screens.first { displayID($0) == id } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
