import Cocoa
import Core
import InputMethodKit

extension azooKeyMacInputController {
    // MARK: - Settings and Menu Items

    func setupMenu() {
        self.appMenu.autoenablesItems = true
        self.liveConversionToggleMenuItem = NSMenuItem(title: "ライブ変換", action: #selector(self.toggleLiveConversion(_:)), keyEquivalent: "")
        self.appMenu.addItem(self.liveConversionToggleMenuItem)
        self.llmDraftMenuItem = NSMenuItem(title: "ローマ字AI変換", action: #selector(self.toggleLLMDraftMode(_:)), keyEquivalent: "")
        self.llmDraftMenuItem.state = Config.LLMDraftMode().value ? .on : .off
        self.appMenu.addItem(self.llmDraftMenuItem)
        self.transformSelectedTextMenuItem = NSMenuItem(title: TransformMenuTitle.normal, action: #selector(self.performTransformSelectedText(_:)), keyEquivalent: "s")
        self.transformSelectedTextMenuItem.keyEquivalentModifierMask = [.control]
        self.transformSelectedTextMenuItem.target = self
        self.appMenu.addItem(self.transformSelectedTextMenuItem)
        self.appMenu.addItem(NSMenuItem.separator())
        self.appMenu.addItem(NSMenuItem(title: "設定…", action: #selector(self.openConfigWindow(_:)), keyEquivalent: ""))
        self.appMenu.addItem(NSMenuItem(title: "View on GitHub…", action: #selector(self.openGitHubRepository(_:)), keyEquivalent: ""))
        self.updateTransformSelectedTextMenuItemEnabledState()
    }

    @MainActor @objc func toggleLiveConversion(_ sender: Any) {
        self.segmentsManager.appendDebugMessage("\(#line): toggleLiveConversion")
        self.setLiveConversion(!self.liveConversionEnabled)
    }

    func updateLiveConversionToggleMenuItem(newValue: Bool) {
        self.liveConversionToggleMenuItem.state = newValue ? .on : .off
        self.liveConversionToggleMenuItem.title = "ライブ変換"
    }

    @MainActor @objc func toggleLLMDraftMode(_ sender: Any) {
        self.setRomajiAIMode(!Config.LLMDraftMode().value)
        self.segmentsManager.appendDebugMessage("toggleLLMDraftMode: \(Config.LLMDraftMode().value)")
    }

    /// ライブ変換の有効/無効を設定する。独立モードのため、ONにするとローマ字AI変換はOFFになる。
    @MainActor func setLiveConversion(_ enabled: Bool) {
        Config.LiveConversion().value = enabled
        self.updateLiveConversionToggleMenuItem(newValue: enabled)
        if enabled {
            Config.LLMDraftMode().value = false
            self.llmDraftMenuItem.state = .off
            self.resetLLMDraftBuffer()
        }
    }

    /// ローマ字AI変換モードの有効/無効を設定する。独立モードのため、ONにするとライブ変換はOFFになる。
    @MainActor func setRomajiAIMode(_ enabled: Bool) {
        Config.LLMDraftMode().value = enabled
        self.llmDraftMenuItem.state = enabled ? .on : .off
        if enabled {
            Config.LiveConversion().value = false
            self.updateLiveConversionToggleMenuItem(newValue: false)
        } else {
            self.resetLLMDraftBuffer()
        }
    }

    private enum TransformMenuTitle {
        static let normal = "いい感じ変換"
        static let noBackend = "いい感じ変換（無効/バックエンドなし）"
    }

    @MainActor @objc func performTransformSelectedText(_ sender: Any) {
        let aiBackendEnabled = Config.AIBackendPreference().value != .off
        self.updateTransformSelectedTextMenuItemTitle(aiBackendEnabled: aiBackendEnabled)
        guard aiBackendEnabled else {
            return
        }
        guard !self.isPromptWindowVisible else {
            return
        }
        guard let client = self.client() else {
            return
        }
        let hasSelection = client.selectedRange().length > 0
        if hasSelection {
            _ = self.handleClientAction(.showPromptInputWindow, clientActionCallback: .fallthrough, client: client)
            return
        }
        switch self.inputState {
        case .composing, .replaceSuggestion:
            _ = self.handleClientAction(.requestReplaceSuggestion, clientActionCallback: .transition(.replaceSuggestion), client: client)
        case .none:
            _ = self.handleClientAction(.requestPredictiveSuggestion, clientActionCallback: .transition(.replaceSuggestion), client: client)
        default:
            break
        }
    }

    @MainActor @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem == self.transformSelectedTextMenuItem else {
            return true
        }
        let aiBackendEnabled = Config.AIBackendPreference().value != .off
        self.updateTransformSelectedTextMenuItemTitle(aiBackendEnabled: aiBackendEnabled)
        return self.canPerformTransformSelectedText(client: self.client())
    }

    func updateTransformSelectedTextMenuItemEnabledState() {
        let aiBackendEnabled = Config.AIBackendPreference().value != .off
        self.updateTransformSelectedTextMenuItemTitle(aiBackendEnabled: aiBackendEnabled)
        self.transformSelectedTextMenuItem.isEnabled = self.canPerformTransformSelectedText(client: self.client())
    }

    private func canPerformTransformSelectedText(client: IMKTextInput?) -> Bool {
        guard !self.isPromptWindowVisible else {
            return false
        }
        guard let client else {
            return false
        }
        let hasSelection = client.selectedRange().length > 0
        return hasSelection || self.inputState == .composing || self.inputState == .replaceSuggestion || self.inputState == .none
    }

    private func updateTransformSelectedTextMenuItemTitle(aiBackendEnabled: Bool) {
        self.transformSelectedTextMenuItem.title = aiBackendEnabled ? TransformMenuTitle.normal : TransformMenuTitle.noBackend
    }

    @objc func openGitHubRepository(_ sender: Any) {
        guard let url = URL(string: "https://github.com/azooKey/azooKey-Desktop") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc func openConfigWindow(_ sender: Any) {
        (NSApplication.shared.delegate as? AppDelegate)!.openConfigWindow()
    }

    // MARK: - Application Support Directory
    func prepareApplicationSupportDirectory() {
        do {
            self.segmentsManager.appendDebugMessage("\(#line): Applicatiion Support Directory Path: \(self.segmentsManager.azooKeyMemoryDir)")
            try FileManager.default.createDirectory(at: self.segmentsManager.azooKeyMemoryDir, withIntermediateDirectories: true)
            self.segmentsManager.appendDebugMessage("\(#line): Debug TypoCorrection Download Directory Path: \(self.segmentsManager.downloadedInputN5LMDir)")
            try FileManager.default.createDirectory(at: self.segmentsManager.downloadedInputN5LMDir, withIntermediateDirectories: true)
        } catch {
            self.segmentsManager.appendDebugMessage("\(#line): \(error.localizedDescription)")
        }
    }
}
