# complexity_budget.d：每條 lane 的 ceiling raise

一個 raise 是一個檔案，檔名為 lane（branch）。effective ceiling = `../complexity_budget.json` 的 base + 本目錄所有 fragment 的 raise 加總。兩條 lane 各加一個檔案，git 不會在同一行衝突，合併順序無關。

格式（`ops/complexity.py` 逐檔驗證，錯誤 exit 2 並點名檔案）：

```json
{"schema": "kg.complexity-budget-raise.v1", "issue": 3155, "raise": {"ops": 150}, "note": "why"}
```

- `issue`：整數 ≥ 0；0 = 無 GitHub Issue（direct assignment）。
- `raise`：area（`ops`、`docs`、`workflows`）→ 正整數。未知 area、非正整數、非整數、空 raise、schema 錯或缺 `note` 皆為錯誤。

寫法：

- 超標時執行 `./ops/complexity.py raise --note "為何"`。只為超標的 area 寫 raise = measured − effective + 5；檔名預設為本 branch（路徑安全化），issue 預設取 branch 的 `issue-<N>`。同一 lane 再次 raise 會累加進同一檔。
- 不要直接改 base 提高 ceiling。舊式寫法仍被 gate 視為「lane 自行提高」，但會與其他 lane 衝突。
- rebase 遇超標時，`ops/deliver.py` 以同一 helper 寫 fragment。

Gate 判斷不變：lane 的 effective ceiling 高於 merge-base 時以絕對值判（measured ≤ effective）；否則只看 lane 自身成長是否在 merge-base headroom 內。

CM 操作：

- `./ops/complexity.py fold`：把所有 fragment 併入 base 並刪除，effective 不變。
- `./ops/complexity.py ratchet`：下調任一 area 時，先把 fragment 併入 base（絕對值）並刪除 fragment；無下調時不動 fragment。
