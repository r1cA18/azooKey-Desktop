import Foundation

/// キーボードショートカットを表す構造体
public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var modifiers: KeyEventCore.ModifierFlag

    public init(key: String, modifiers: KeyEventCore.ModifierFlag) {
        self.key = key
        self.modifiers = modifiers
    }

    /// デフォルトのショートカット（Control+S）
    public static let defaultTransformShortcut = KeyboardShortcut(
        key: "s",
        modifiers: .control
    )

    /// ローマ字AI変換を実行するデフォルトショートカット（Control+Option+J）
    public static let defaultRomajiAIConvertShortcut = KeyboardShortcut(
        key: "j",
        modifiers: [.control, .option]
    )

    /// ライブ変換とローマ字AI変換を切り替えるデフォルトショートカット（Control+Option+M）
    public static let defaultSwitchInputAssistModeShortcut = KeyboardShortcut(
        key: "m",
        modifiers: [.control, .option]
    )

    /// 表示用の文字列（例: "⌃S"）
    public var displayString: String {
        var result = ""

        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }

        result += key.uppercased()
        return result
    }
}

protocol KeyboardShortcutConfigItem: ConfigItem<KeyboardShortcut> {
    static var `default`: KeyboardShortcut { get }
}

extension KeyboardShortcutConfigItem {
    public var value: KeyboardShortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.key) else {
                return Self.default
            }
            do {
                let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
                return decoded
            } catch {
                return Self.default
            }
        }
        nonmutating set {
            do {
                let encoded = try JSONEncoder().encode(newValue)
                UserDefaults.standard.set(encoded, forKey: Self.key)
            } catch {
                // エンコード失敗時は何もしない
            }
        }
    }
}

extension Config {
    /// いい感じ変換のキーボードショートカット
    public struct TransformShortcut: KeyboardShortcutConfigItem {
        public init() {}

        public static let `default`: KeyboardShortcut = .defaultTransformShortcut
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.transform_shortcut"
    }

    /// ローマ字AI変換を実行するキーボードショートカット
    public struct RomajiAIConvertShortcut: KeyboardShortcutConfigItem {
        public init() {}

        public static let `default`: KeyboardShortcut = .defaultRomajiAIConvertShortcut
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.romaji_ai_convert_shortcut"
    }

    /// ライブ変換とローマ字AI変換を切り替えるキーボードショートカット
    public struct SwitchInputAssistModeShortcut: KeyboardShortcutConfigItem {
        public init() {}

        public static let `default`: KeyboardShortcut = .defaultSwitchInputAssistModeShortcut
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.switch_input_assist_mode_shortcut"
    }
}
