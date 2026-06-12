# LLM Draft Mode（未変換ひらがなの段落をLLMで漢字変換）

## 目的

基本動作は通常のazooKey（Zenzaiライブ変換・スペース変換そのまま）。それに加えて、
**ひらがなのまま確定されたテキスト**を追跡しておき、空行(未確定なしのEnter)が来たら、
その未変換ひらがな段落を同期的にLLM(OpenAI API)で漢字かな交じり文へ変換する。

ローマ字をひらがなで打ち進め、思考を止めずに段落を書き、空行で一括変換する体験を狙う。
参考: 自作エディタにこの方式を実装した事例（X投稿）、Sumibi（ローマ字→かな前処理で精度向上）。

## 確定済みの設計判断

- 入力体験: 通常のazooKeyのまま。ひらがな確定したテキストだけが変換対象に溜まる
- 変換発火: **空行（未確定なしのEnter）**。直前の未変換ひらがな段落をまとめて変換
- 打ち切り: 漢字・カタカナに変換確定したら累積をリセット。**スペースでZenzai変換した部分は
  自動でLLM対象外**（共存）。最後が変換済みなら空行でも変換は走らない
- 変換後: 改行を1つ入れてカーソルを次行頭へ（段落間に空行は残さない）
- LLMバックエンド: まず OpenAI API（既存 AIClient 経由）。Ollama対応は後（プラスアルファ）
- 安全装置として menu トグル `Config.LLMDraftMode` で ON/OFF（OFF時は既存動作が完全に不変）

## アーキテクチャ（確定テキスト追跡方式）

```
[基本] 通常のazooKey入力（横取りしない）
  ↓ azooKeyの確定経路（submitCandidate / commitMarkedText 系 / commitComposition）
[フック] recordLLMDraftCommittedText(text)
  - isPlainHiragana(text) == true  → llmDraftPlainHiraganaLength += text.utf16長
  - false（漢字・カタカナ等）        → llmDraftPlainHiraganaLength = 0（打ち切り）
  ↓
[空行Enter] handleLLMDraftMode → startLLMDraftConversion
  - 範囲 = カーソル位置から累積長ぶん遡る（確定直後の selectedRange に依存しない）
  - 実テキストを client.string で取得し、要求範囲と一致 & 全て未変換ひらがな を再検証
  - 検証OK → 非同期Taskで LLM変換 → range一致を再検証して置換 → 改行1つ
  - 検証NG・変換中 → 変換を開始せず Enter を消費しない（通常の改行に委ねる）
```

## なぜ「累積長 + カーソル逆算」なのか（レビュー反映）

個別の挿入rangeを確定ごとに記録する方式は、`insertText` 直後の `selectedRange()` が
アプリ依存で不安定（特にChromium系）という問題があった。そこで確定時には**長さだけ**を
足し、実際の範囲は変換時のカーソル位置から逆算し、`client.string` で取った実テキストを
再検証する方式にした。これにより確定経路フックは軽くなり、誤った範囲での変換を防ぐ。

## 既存資産マッピング（流用したもの）

| やること | 既存メソッド/箇所 | 備考 |
|---|---|---|
| ひらがな確定の検出 | `submitCandidate` / `commitMarkedText` 系 / `commitComposition` | 全確定経路にフック |
| 非同期LLM呼び出し | `AIClient.sendTextTransformRequest` (AIBackend.swift) | endpoint/model/key 外部化済み |
| 範囲置換 | `client.insertText(_, replacementRange:)` | IMK標準 |
| 範囲の実テキスト取得 | `client.string(from:actualRange:)` | actualRange も検証 |
| エンドポイント/モデル設定 | `Config.OpenAiApiEndpoint/ModelName` / `OpenAiApiKey`(SecureConfigItem) | 既存 |
| メニュートグル | `liveConversionToggleMenuItem` パターン | これに倣う |

## 実装ファイル

- `Core/Sources/Core/Configs/BoolConfigItem.swift` — `Config.LLMDraftMode`(default false)
- `azooKeyMac/InputController/azooKeyMacInputController+LLMDraftMode.swift`（新規・本体）
  - `handleLLMDraftMode` / `recordLLMDraftCommittedText` / `resetLLMDraftBuffer`
  - `isPlainHiragana` / `startLLMDraftConversion` / `convertParagraphViaLLM` / `replaceParagraphIfMatches`
- `azooKeyMac/InputController/azooKeyMacInputController.swift`
  - プロパティ `llmDraftPlainHiraganaLength` / `isLLMDraftConverting` / `llmDraftMenuItem`
  - `handle()` 早期分岐、全確定経路へのフック、`deactivateServer`/`switchInputLanguage` でのリセット
- `azooKeyMac/InputController/azooKeyMacInputControllerHelper.swift` — メニュートグル

## 堅牢性（レビューで対応した点）

- 全確定経路（`commitComposition`・`commitMarkedTextAndAppend*`・`commitMarkedTextAndSelectInputLanguage`含む）にフック
- range計算は累積長 + カーソル逆算 + 実テキスト再検証（タイミング問題回避）
- 置換は range と実テキストの両方が一致したときのみ（誤置換防止）
- 改行は**置換成功時のみ**（失敗時はカーソル位置が保証できないため入れない）
- 変換中Enterは握りつぶさず通常の改行に委ねる
- モードOFF / deactivate / 入力言語切替で `resetLLMDraftBuffer`
- モードOFF時は `recordLLMDraftCommittedText` が即returnし、既存動作は一切変わらない

## 未決事項 / 将来

- **変換の非同期化（本命改善）**: 空行で改行を即入れてカーソルを次段落へ進め、変換は裏で
  走らせる。前段落の置換でカーソルがずれないよう delta 補正が必要（現状は同期）
- 変換中に積まれた次段落のキューイング（現状は次のEnterで処理）
- 会話履歴・文体/固有名詞カスタマイズ（messages対応API）
- Ollama対応（`response_format` の差異吸収）
- ライブ変換ON環境での体感調整（ひらがな確定が発生しにくいため、運用はライブ変換OFFが自然）
