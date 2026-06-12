import Cocoa
import Core
import Foundation
import InputMethodKit

// MARK: - LLM Draft Mode
//
// ライブ変換と排他の独立モード。モードON時はライブ変換がOFFになり、確定テキストは
// 素のひらがなのまま溜まる。「ひらがなのまま確定されたテキスト」の累積長を追跡しておき、
// 専用ショートカット（Config.RomajiAIConvertShortcut、既定 ⌃⌥J）が押されたら、その未変換
// ひらがな段落を同期的にLLM(OpenAI API / Foundation Models)で漢字かな交じり文へ変換する。
//
// 漢字・カタカナに変換確定された場合は累積長を 0 に戻すため、スペースでZenzai変換した
// 部分は自動的にLLM変換の対象外になる（共存）。
//
// 段落の範囲は「変換時のカーソル位置から累積長ぶん遡る」で求め、実テキストを再検証してから
// 変換・置換する。これにより確定直後の selectedRange のタイミング問題を回避する。
//
// PoC段階: バックグラウンド非同期化・会話履歴・複数段落並行・Ollamaは未対応。
extension azooKeyMacInputController {

    /// 段落変換のための保留情報。置換前に originalText・range の一致を検証してから差し替える。
    struct LLMDraftPendingParagraph {
        let originalText: String
        let currentRange: NSRange
    }

    enum LLMDraftError: Error {
        case backendOff
        case noAPIKey
    }

    /// azooKeyの確定経路からフックされる。確定テキストが「未変換ひらがな」なら累積長に加算し、
    /// 「変換済み（漢字・カタカナ）」なら累積長を 0 に戻して打ち切る。
    @MainActor
    func recordLLMDraftCommittedText(_ text: String) {
        guard Config.LLMDraftMode().value, !text.isEmpty else {
            return
        }
        if Self.isPlainHiragana(text) {
            self.llmDraftPlainHiraganaLength += (text as NSString).length
        } else {
            self.llmDraftPlainHiraganaLength = 0
        }
    }

    /// LLM Draft Mode のバッファをリセットする（モードOFF・deactivate・入力言語切替時）。
    @MainActor
    func resetLLMDraftBuffer() {
        self.llmDraftPlainHiraganaLength = 0
        self.isLLMDraftConverting = false
    }

    /// テキストが漢字・カタカナ・英字を含まない「未変換ひらがな」かどうか。
    /// ひらがなを1文字以上含み、変換済みを示す文字（漢字/カタカナ/英字）を含まない場合に true。
    /// 句読点・長音符 ー(U+30FC)・中点 ・(U+30FB)・記号・数字・スペース等は中立として許容する。
    static func isPlainHiragana(_ text: String) -> Bool {
        var hasHiragana = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F:
                // ひらがな
                hasHiragana = true
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                // CJK統合漢字
                return false
            case 0x30A1...0x30FA, 0x30FD...0x30FF:
                // カタカナ（中点 ・(U+30FB) と長音符 ー(U+30FC) は中立として許容するため除外）
                return false
            case 0x0041...0x005A, 0x0061...0x007A, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                // 半角・全角ラテン文字
                return false
            default:
                // 句読点・長音・記号・数字・スペース等は中立
                break
            }
        }
        return hasHiragana
    }

    /// 溜まった未変換ひらがな段落の変換を開始する。開始できたら true を返す。
    /// 範囲は「現在のカーソル位置から累積長ぶん遡る」で求め、実テキストを再検証する。
    @MainActor
    func startLLMDraftConversion(client: IMKTextInput) -> Bool {
        guard !self.isLLMDraftConverting else {
            return false
        }
        let length = self.llmDraftPlainHiraganaLength
        guard length > 0 else {
            return false
        }
        let caret = client.selectedRange().location
        guard caret != NSNotFound, caret >= length else {
            return false
        }
        let paragraphRange = NSRange(location: caret - length, length: length)

        // ドキュメント上の実テキストを取得し、要求した範囲と一致し、かつ全て未変換ひらがなか検証する
        var actualRange = NSRange()
        guard let originalText = client.string(from: paragraphRange, actualRange: &actualRange),
              !originalText.isEmpty,
              actualRange.location == paragraphRange.location,
              actualRange.length == paragraphRange.length,
              Self.isPlainHiragana(originalText) else {
            self.segmentsManager.appendDebugMessage("LLM Draft: paragraph verification failed, skip")
            return false
        }

        self.llmDraftPlainHiraganaLength = 0
        let pending = LLMDraftPendingParagraph(originalText: originalText, currentRange: paragraphRange)
        self.isLLMDraftConverting = true
        Task { @MainActor in
            defer { self.isLLMDraftConverting = false }
            var didReplace = false
            do {
                let converted = try await self.convertParagraphViaLLM(originalText)
                didReplace = self.replaceParagraphIfMatches(pending, with: converted, client: client)
            } catch {
                // 失敗時はひらがなのまま残す
                self.segmentsManager.appendDebugMessage("LLM Draft conversion failed: \(error)")
            }
            // 置換に成功したときだけ改行を入れてカーソルを次行頭へ置く。
            // 失敗時はカーソル位置が保証できないため改行しない（ひらがなのまま残す）。
            if didReplace {
                client.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        return true
    }

    /// ひらがな段落をLLMで漢字かな交じり文に変換する（同期 await）。
    @MainActor
    private func convertParagraphViaLLM(_ hiragana: String) async throws -> String {
        let preference = Config.AIBackendPreference().value
        guard preference != .off else {
            throw LLMDraftError.backendOff
        }
        let backend: AIBackend = preference == .foundationModels ? .foundationModels : .openAI
        let apiKey = Config.OpenAiApiKey().value
        if backend == .openAI, apiKey.isEmpty {
            throw LLMDraftError.noAPIKey
        }
        let modelName = Config.OpenAiModelName().value
        let endpoint = Config.OpenAiApiEndpoint().value.isEmpty
            ? Config.OpenAiApiEndpoint.default
            : Config.OpenAiApiEndpoint().value

        let prompt = """
        次のひらがなの文章を、自然な漢字かな交じり文に変換してください。
        意味は変えず、改行の位置はそのまま保ってください。変換結果のテキストだけを返してください。

        \(hiragana)
        """

        return try await AIClient.sendTextTransformRequest(
            prompt,
            backend: backend,
            modelName: modelName,
            apiKey: apiKey,
            apiEndpoint: endpoint
        )
    }

    /// 保留 range の現在の内容が originalText と一致する場合のみ置換する（誤置換防止）。
    /// 置換を実行したら true を返す。
    @MainActor
    private func replaceParagraphIfMatches(_ pending: LLMDraftPendingParagraph, with converted: String, client: IMKTextInput) -> Bool {
        var actualRange = NSRange()
        let current = client.string(from: pending.currentRange, actualRange: &actualRange) ?? ""
        guard current == pending.originalText,
              actualRange.location == pending.currentRange.location,
              actualRange.length == pending.currentRange.length else {
            self.segmentsManager.appendDebugMessage("LLM Draft: range mismatch, skip replace")
            return false
        }
        client.insertText(converted, replacementRange: pending.currentRange)
        return true
    }
}
