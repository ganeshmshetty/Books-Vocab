---
name: ios-simulator-verification
description: "KG iOS Simulator／UITest 的隔離執行、證據判讀與可重現 hand-back 路由；技術契約以 domain docs 為準。"
---

# iOS Simulator verification route

這個 skill 只負責把 iOS Simulator／UITest 工作協調成一個可驗證的 run；命令、
verdict schema、UI World、artifact TTL 與 DerivedData 細節以以下 SoT 為準：

- [`docs/sop/ios.md`](../../../docs/sop/ios.md)：iOS build／test／device／release 邊界。
- [`docs/sop/ui_flow_evidence.md`](../../../docs/sop/ui_flow_evidence.md)：flow evidence、
  visual run、P3–P15 matrix contract。
- [`docs/reference/ios_deriveddata_policy.md`](../../../docs/reference/ios_deriveddata_policy.md)：
  cache、lock、Simulator lease 與 cleanup。
- [`docs/sop/ui-design.md`](../../../docs/sop/ui-design.md)：UI 修改的設計與 i18n 邊界。

## 觸發與前置

只在 onboarding `status=ready` 且 intent 是 `ios`／`simulator-verification`／
`ui-test-evidence`，**並且**工作涉及 UI 或 Simulator evidence（UI 畫面、UITest selector、
UI World、flow evidence）時載入。非 UI 的 iOS model／service 變更不需要 Simulator 證據：
走 `delivery-worktree`（worktree-flow）交付，以 unit tests 與 CI 為準，不在此 skill 內產生
UI evidence。開始前確認：

1. 已有 Worker／Issue Solver 的 branch、worktree、structured Scope、exact HEAD。
2. source tree、UI World／dataset、selector、Simulator lease 與 evidence 目的已明確。
3. 目前任務是 Simulator 證據；它不能升格為真機、TestFlight、App Store 或 production 證據。

缺少 UI World、exact selector、clean source、可識別 device／lease 或必要 tool 時，
停在 `inconclusive`，不要用任意 booted simulator、舊 run、真 backend 或座標操作補洞。

## 固定執行路徑

```text
preflight (branch/HEAD/dirty/tool/UI World)
  → exact selector on leased Simulator
  → normalized verdict + run-scoped evidence contract
  → required behavior assertions
  → optional visual review／attestation
  → compact receipt + PR hand-back
```

標準 helper 是：

```bash
./.claude/skills/ios-simulator-verification/scripts/run_ui_evidence.sh \
  --dataset <dataset> --method <ClassName/testMethodName> --lease --json-out <verdict.json>
```

只用 repo 既有 helper／`ops/ios_ops.sh`；不要自行 erase simulator、刪 lock、拼
xcodebuild 或建立第二份 evidence schema。heartbeat 只作 observability；raw log silence
不是卡死證據，不得直接因此 kill xcodebuild／runner。終止依 XCTest allowance、command/job
timeout 與已證明的 owner／PID／lock cleanup contract；等待期間做不競爭 Xcode lock 的
source／fixture／receipt 工作。

## 判讀與交接

- `status=result=ok`、`exit=0` 且 `executed>0` 才是 machine behavior pass；JSON 能解析或
  process 曾啟動不算 pass。
- `fail` 先讀 normalized run bundle 的第一個 assertion、stderr、log、xcresult 與
  source／fixture identity；`inconclusive` 不可改寫成產品 fail 或 pass。
- 視覺 run 只在 assignment 明確需要時啟動；依 `ui_flow_evidence.md` 完成全步驟人工
  attestation，二進位產物預設短命，不能把一次 run 直接寫成永久 status。
- 修復後用同一 exact selector、同一 fixture contract 重跑；source、dataset、device 或
  selector drift 就重新建立 evidence，不混用舊 bundle。

交接必須包含：branch／exact HEAD／dirty、dataset ID／SHA、Simulator UDID／lease、exact
selector、command／exit status、normalized verdict、behavior assertions、必要 visual
attestation、log／xcresult identity、docs impact、deviation、blocker 與下一步。最後由
CR／DS／CM 依 PR、Actions、docs gate 收斂；本 skill 不負責 merge 或 release。
