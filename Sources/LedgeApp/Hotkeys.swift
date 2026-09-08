import AppKit
import Carbon.HIToolbox

/// Global shortcuts through Carbon's `RegisterEventHotKey`.
///
/// Deliberately *not* `NSEvent.addGlobalMonitorForEvents`, which would achieve
/// exactly the same thing while demanding Accessibility permission. With no Dock
/// icon there is no menu bar to hang shortcuts off, so these have to be global —
/// and they should not cost the user a scary dialog on first launch.
@MainActor
final class Hotkeys {

    struct Shortcut {
        var key: Int
        var modifiers: UInt32
        static func optionCommand(_ key: Int) -> Shortcut {
            Shortcut(key: key, modifiers: UInt32(optionKey | cmdKey))
        }
    }

    private static var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var installed = false

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        Hotkeys.actions[id] = action

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C444745), id: id)   // 'LDGE'
        RegisterEventHotKey(UInt32(shortcut.key), shortcut.modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    fileprivate static func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let value = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Hotkeys.fire(value) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Hotkeys live for the lifetime of the process; unregistering happens here
    /// rather than in `deinit`, which cannot touch actor-isolated state.
    func unregisterAll() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref) }
        refs.removeAll()
        Hotkeys.actions.removeAll()
    }
}

extension Hotkeys.Shortcut {
    static let newNote  = Hotkeys.Shortcut.optionCommand(kVK_ANSI_N)
    static let allNotes = Hotkeys.Shortcut.optionCommand(kVK_ANSI_A)
    static let archive  = Hotkeys.Shortcut.optionCommand(kVK_ANSI_L)
    static let showDeck = Hotkeys.Shortcut.optionCommand(kVK_ANSI_D)
}
