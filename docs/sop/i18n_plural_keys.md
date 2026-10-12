<!-- doc-meta
tier: sop
authority: derived
update_trigger: sop-change
scope:
  - ios/
  - ops/
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# i18n Plural Keys

走 `L10n.format(_:_:)` 配 `%lld` 引發 Apple `NSStringPluralRuleType` 變化。鍵定義在
各 `ios/BooksAndVocab/<lang>.lproj/Localizable.stringsdict`。

## Pipeline

- 呼叫:`L10n.format("<key>", Int64(count))`
- 解析:`L10n.format` → `lookup(key)`(三層 fallback)→ `NSString(format:locale:)`,
  locale-aware plural rule engine 處理 `%#@var@` 展開。
- iOS 17+ 內建 5 種語言的 plural rule(en: one/other,zh-Hant/zh-Hans/ja/ko: other)。

## 既有 keys

5 個 `.stringsdict`（en / zh-Hant / zh-Hans / ja / ko）共有以下 plural key（en 走 `one`/`other`，CJK 通常只 `other`）：

| key | 用途 |
|-----|------|
| `card_count_plural` | 卡片計數（書架 / notebook stats） |
| `vocab_total_cards_plural` | Vocab 總卡片數 |
| `vocab_due_cards_plural` | 今日待複習數 |
| `vocab_reviewed_cards_plural` | 已複習數 |
| `vocab_graph_node_count_plural` | 知識圖譜 node 數 |
| `vocab_graph_link_count_plural` | 知識圖譜 link 數 |
| `notebook.dueCount` | Notebook 卡片待複習數 |
| `notebook.unlearnedCount` | Notebook 尚未學習數 |
| `vocab.reviewProgress.percent` | 單字列複習進度百分比（僅 WordRow 使用；閱讀進度百分比統一走 `ReadingProgressFormatter`） |

> Welcome banner 另有 2 個 raw 中文 plural key（`已收錄 %d 個單字...`）使用 stringsdict 機制但 key 本身是字面字串 — 待 Phase 6 i18n sweep 收尾後改 snake_case。

## 新增 plural key 流程

1. 5 個 `.stringsdict` 都加同一個 key,共用 `NSStringLocalizedFormatKey`
2. `NSStringFormatSpecTypeKey = NSStringPluralRuleType`
3. `NSStringFormatValueTypeKey = lld`(Int64;`%d` + Int 在 64-bit 平台對齊不穩,**禁用**)
4. en 必填 `one` + `other`;CJK 語言通常只需 `other`(無單複數)
5. 呼叫端用 `Int64(value)` 或顯式 `Int64` 變數

## 不適用 plural 的場景

- 純字串內嵌(`"\(count) 集"`)無 locale variation → 走 raw `L10n.string` 或維持 raw 中文 + Phase 6 清除
- 多參數計數(`"%d 詞 · %d 連結"`)plist 不支援單一 key 雙 plural,拆 2 key

## 與 lint 連動

`ops/i18n_lint.sh --strict`（Check C — Plural Rules）對 `L10n.format(<key>, …)` 的 key（en `.strings` 值含 `%d`/`%lld`，或 en `.stringsdict` 已有該 key）逐一檢查 en／zh-Hant／zh-Hans／ja／ko 五個 `Localizable.stringsdict`：任一語系缺 entry（含檔案缺失或無法解析）、變數的 `NSStringFormatSpecTypeKey` 非 `NSStringPluralRuleType`、`NSStringFormatValueTypeKey` 非 `lld`，或 en 缺 `one`／`other`，皆擋 PR。其他語系的 form 子集（如 ja／ko 只需 `other`）不檢查。詳見 `docs/sop/i18n_lint.md`。
