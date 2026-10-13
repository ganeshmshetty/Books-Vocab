<!-- doc-meta
tier: sop
authority: derived
update_trigger: release-change
scope:
  - .github/workflows/
  - ops/release.sh
  - ops/release_report.py
  - ops/devops_kg_safe.sh
  - ops/kg_reconcile.sh
  - backend/
  - ios/
verified_against: 24f2120d7118af81b6812a50a4c489aff3b466ec
-->
# Release SOP

## Mental model

[`docs/reference/delivery_model.md`](../reference/delivery_model.md) 定義 CM 對 codebase、merge 與 release／deploy 邊界的責任。GitHub `main` is the merged product truth. A PR merge records code review and required checks; it is not by itself permission to publish or deploy. A release is an explicit, traceable action with a version, target surface, approval, health verification and rollback path.

| Concern | Source of truth | Entry |
|---|---|---|
| Code and review | GitHub PR merged to `main` | GitHub |
| Version and release notes | repository release metadata | `ops/release.sh status/changelog`；維護中的 changelog 在 `docs/reference/changelog/{ios,api}.md`（`release` 時 Unreleased 節改名為新版號） |
| Backend production state | production ref／container health | `ops/release.sh` + `ops/devops_kg_safe.sh` |
| iOS build/TestFlight | App Store Connect and build artifacts | `docs/sop/ios.md`、`ops/ios_release.sh` |
| Cross-surface release diff | Git anchors + ASC + live probe | `ops/release_report.py` |
| Rollback | previous known-good version／image／ref | deploy SOP and safety wrapper |

## Required sequence

1. CM confirms the PR is merged to the intended `main` and the merged SHA is known.
2. Run release status and inspect changed surfaces, migrations, configuration and compatibility risks.
   Run `./ops/release_train.py` for backend: it must report no `block` (prod fast-forward, formatted release files, an `origin/prod`-exact felix clone, healthy reconciler, fresh backup, production env) and lists hot-path files that need the owner's explicit go.
3. Select backend, iOS, or both. Do not publish a surface that was not explicitly selected.
4. The releasing agent decides the version (semver from the changes since the last shipped tag: feature = minor, fixes only = patch, breaking API/data change = major) and writes the changelog itself; no user confirmation is needed for either, and the report and PR state the chosen version with a one-line reason. Run the release entrypoint in dry-run mode first as the agent's own verification, and confirm target, approval and rollback candidate.
5. Execute only the approved release command. Production writes must pass the safety wrapper and health gate.
6. Verify the deployed/build state independently and record the exact version and evidence.
7. If health verification fails, stop traffic or revert according to `docs/sop/deploy.md`; do not improvise a second path.

## Candidate state machine and recovery

`ops/release.sh release <backend|ios> <version>` and `resubmit ios` are candidate
commands. They must run in the dedicated owner lane. With `--yes` they may change
only the assigned version files and create a deterministic candidate commit; they do
not push a branch, update protected `main`, upload to ASC, deploy backend, or create a
tag. The owner then runs the supported worktree hand-back and IM publishes that exact
commit as one PR:

The candidate lane must be clean and its `HEAD` must equal a fresh live
`origin/main` read immediately before the version transaction. A non-main branch by
itself is not sufficient: an ahead branch could carry unreviewed product changes, and
a behind branch could create a stale release candidate. `release` and `resubmit`
reject both cases before changing version files or creating a candidate commit
(they may read the current tuple first to recognize an existing pending candidate);
re-materialize a fresh supported lane from the new live main instead of rebasing,
copying, or using the canonical development checkout.

`./ops/release.sh status` uses two different iOS boundaries. The latest
`ios/<version>` tag means that marketing version was verified as App Store
shipped; it is not the source boundary for a build that has already been
sealed. If the current Xcode `(MARKETING_VERSION, CURRENT_PROJECT_VERSION)`
tuple has an immutable `ios/<version>+<build>` tag reachable from the current
checkout, status counts only iOS commits after that build tag as an unsealed
candidate backlog. Commits after the build tag are still real work and remain
visible.

Status is an observation only. A sealed build tag does not authorize an ASC
upload, a PR merge, a tag push, or a deployment; those actions still require
the dedicated release lane, exact merged-main evidence, and the corresponding
release command gates below.

The release agent is independent from the development checkout. If it does not
already have a dedicated lane, materialize one from the **live** `origin/main` before
running `release` or `resubmit`; never turn the canonical `main` checkout into a
candidate. The open command is the supported ownership boundary (the external ID and
thread ID are durable evidence, not chat-only labels):

```bash
LIVE_MAIN="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
./ops/worktree_orchestrate.py open --json \
  --intent "iOS release <version>+<build>" \
  --slug "release-ios-<version>-<build>-<date>" \
  --base "$LIVE_MAIN" \
  --external-id "DIRECT-RELEASE-IOS-<version>-<build>-<date>" \
  --scope '{"schema":"kg.worktree.scope.v1","files":[{"path":"ios/BooksAndVocab.xcodeproj/project.pbxproj","operation":"modify"}]}' \
  --codex-thread-id "$RELEASE_AGENT_THREAD" --delegated
```

For `resubmit`, `<build>` is the exact target printed by the dry-run after the ASC
readback; it is not a manually guessed number. Run the release command only from the
returned worktree, preserve its exact branch/base/Scope, and hand back through
`worktree_orchestrate.py`. If the open/preflight command reports a collision, malformed
ownership, or a main-SHA drift, stop and re-read live state rather than using the
canonical checkout as a fallback.

```text
dedicated lane candidate
  -> supported worktree_orchestrate hand-back
  -> IM publishes the exact commit as one PR
  -> required check + native merge queue on protected main
  -> CM exact merged receipt + canonical main sync
  -> ASC upload only if exact build is not already present
  -> exact ASC proof
  -> finalize tag-only push
```

For iOS, resume only after the PR is merged and canonical `main` is synced to the
live `origin/main`. Supply both immutable merge evidence fields; the candidate SHA
does not need to equal the merged main SHA:

```bash
./ops/release.sh resume ios <version> <build> \
  --pr <merged-pr-number> --merged-source <40-char-merged-source-sha>
./ops/release.sh resume ios <version> <build> \
  --pr <merged-pr-number> --merged-source <40-char-merged-source-sha> --yes
```

`--pr` is not an attestation. Before any ASC upload or tag push, `resume` and
`finalize` perform an exact GitHub PR readback (normally `gh pr view`; tests may
inject a one-argument `KG_PR_CMD`). The readback must be one PR object whose
number matches, `state=MERGED`, `baseRefName=main`, `headRefOid` equals
`--merged-source`, `mergeCommit.oid` is an exact commit ancestor of live
`origin/main`, and `baseRefOid` is an ancestor of both source and live main.
The live tip may include later merged PRs, so the release agent can run in
parallel with development; after the PR is merged and canonical `main` is
synced, resume with a fresh live readback. Readback failure, wrong/open PR,
source mismatch, missing/non-commit/non-ancestor merge commit, or invalid base
is fail-closed before ASC or tag side effects; PR body and branch name are not
guessed as evidence.

The first command is a dry-run. The `--yes` form probes exact ASC first, uploads only
when that exact `(version, build)` is absent, and then calls the tag-only finalizer.
If upload or ASC propagation fails, keep the merged main and run the same resume
command again after checking ASC; it never bumps a new build. If upload already
landed, the exact ASC probe skips a second upload. To recover only the final tag:

```bash
./ops/release.sh finalize ios <version> <build> \
  --pr <merged-pr-number> --merged-source <40-char-merged-source-sha>
./ops/release.sh finalize ios <version> <build> \
  --pr <merged-pr-number> --merged-source <40-char-merged-source-sha> --yes
```

`finalize` requires current local `main == live origin/main`, proves the merged source
is an ancestor, checks exact ASC state, and pushes only `ios/<version>+<build>`; it never
pushes a branch ref. If live `origin/main` already contains the requested iOS tuple,
the candidate command refuses to create another build and points to `resume`.

## Backend

Use `ops/release.sh release backend <version>` only to create the dedicated-lane
candidate. After PR/queue merge and canonical sync, an approved release operator may
run `ops/release.sh promote backend <sha>` (see [felix 生產切換](#felix-生產切換backend-production-promotion)). The
candidate path never pushes `main` and never deploys. `ops/kg_reconcile.sh` is the
host-side convergence service when enabled; its health gate and rollback behavior are
part of the deployment contract. Database migrations, secrets, domain routing,
container ports and host ownership remain governed by `docs/sop/deploy.md` and
`docs/reference/host_topology.md`.

### felix 生產切換（backend production promotion）

`origin/prod` is the only production cursor: the felix reconciler (`ops/kg_reconcile.sh`, launchd `com.kg.reconcile`, repo `~/kg-prod`) deploys whatever `origin/prod` points at. `promote` is the one scripted way to advance it. The branch is not GitHub-protected, so the guards live in the script; never push `prod` by hand.

```bash
./ops/release.sh promote backend <full-40-char-main-sha>                  # dry-run: all guards, prints plan, pushes nothing
./ops/release.sh promote backend <sha> --yes --wait                       # git push origin <sha>:refs/heads/prod, then poll
./ops/release.sh promote backend <sha> --same-version "<reason>" --yes    # redeploy without a version bump
```

Preconditions (each refuses with a message; the push is lease-guarded, there is no unconditional `--force`, and the ancestry guard enforces fast-forward):

1. `<sha>` is a full SHA and an ancestor of the live `refs/heads/main` tip. Refs are matched by exact full name (a stray `a/main` or `a/prod` branch is never mistaken for them).
2. Live `origin/prod` is an ancestor of `<sha>`: fast-forward only.
3. `backend/pyproject.toml` and `backend/src/kg/api.py` agree at `<sha>` and are greater than the version at `origin/prod` (equal only with `--same-version <reason>`).
4. The newest `backend-quality` check-run (highest run id) of every check suite of `<sha>` is `completed`/`success` (`gh api --paginate .../commits/<sha>/check-runs?filter=all&per_page=100`, all pages merged, names selected client-side, grouped by `check_suite.id`). Strict: skipped, neutral, in-progress, missing, truncated, unparseable or id-less evidence refuses, and so does a failure in a different suite; an older failed attempt superseded by a green re-run inside the same suite (`filter=all` keeps it) no longer blocks.

The gate accepts exactly two check-run names, matched exactly (no prefix or substring match): `backend-quality / backend-quality` (caller job `backend-quality` in `pr-gate.yml` / reusable job `backend-quality` in `backend-quality.yml`, PR and merge-queue runs) and `backend-quality` (the `backend-quality.yml` run triggered by push to `main`; verified 2026-10-13 on `0ca410d5c` as run 38349139156, the only backend-quality check-run on that commit, whereas `30b12177f` (2026-10-10) carried the PR-caller name). Both names are evaluated together per check suite, so a failure in either suite refuses. The sibling `backend-quality / image-lock` is not counted. If either workflow is ever renamed or nested differently, every SHA is refused and the gate must be updated.

The push is `git push --force-with-lease=refs/heads/prod:<observed-prod> origin <sha>:refs/heads/prod`: if anyone moves `prod` between the checks and the push, it is refused. `--same-version` also appends `<time> promote backend <sha> same-version <ver> reason=<reason>` to the local `.cache/release/promote.log` and echoes the reason in the push output.

Run `./ops/release_train.py` first and get the owner's explicit go for hot-path files. After the push the script re-reads `origin/prod` and must see `<sha>`.

What happens next (no operator action): within about 90 s the reconciler fast-forwards `~/kg-prod`, rebuilds and force-recreates the container, runs the localhost health and external smoke gates, and on failure rolls back to the previous SHA and poisons the new one (cooldown 3600 s). Details and verdicts: `docs/sop/deploy.md` (reconciler sections).

Verify: `--wait` polls `GET ${KG_PUBLIC_URL:-https://wordnexus.lol}/api/system/info` every 15 s (up to 600 s; `KG_PROMOTE_POLL_SECS`/`KG_PROMOTE_WAIT_SECS`) until `version` is a prefix of the promoted SHA (at least 7 chars). Without it, run the same `curl` plus `./ops/devops_kg_safe.sh run "tail -40 ~/Library/Logs/kg_reconcile.err.log"` and `tail -5 ~/Library/Logs/kg_reconcile.out.log` (verdict `deployed` expected; `rolled-back` or `poisoned-skip` means the gate failed).

Rollback: the reconciler refuses rewinds, and `promote` refuses non-fast-forward, so never move `prod` backwards. Land a forward `git revert` of the bad change on `main` through the normal PR and merge queue (bump the backend version so the guard passes, or use `--same-version`), then `promote` that commit. If a gate already auto-rolled back, the bad SHA is poisoned and production is on the old SHA; fix forward the same way. First-time provisioning (clone `~/kg-prod`, seed `origin/prod`, plist) is a one-off topology migration, recorded in `docs/reference/host_topology.md`.

Backfill a missing historical tag: `ops/release.sh tag api <x.y.z> --commit <sha> [--yes]` (dry-run by default) tags an exact commit without committing or moving any branch. It refuses when the commit is not a valid commit, its `backend/pyproject.toml` (and `api.py`) version differs from `<x.y.z>`, it is not an ancestor of live `origin/prod` (never shipped), or the tag already exists locally or on origin; the push is tag-only.

## iOS

Use `docs/sop/ios.md` for signing, build, TestFlight and App Store Connect operations. Keep build verification, metadata changes and submission as separate decisions; an uploaded build is not an approved store release.

## Cross-surface provenance report

Before answering a version-gap question, run the read-only report so the answer is bound to
the same evidence window:

```bash
./ops/release_report.py snapshot
./ops/release_report.py snapshot --json
```

The report keeps Git, App Store Connect and backend live state separate. `ios/<version>+<build>`
is the source binding for a TestFlight binary; `ios/<version>` is the shipped App Store source
binding created only after the ASC state is verified. For backend, compare `origin/prod` to
`origin/main`, then separately compare live `/api/system/info` to `origin/prod`. Missing source
bindings are `blocked`, never a guessed match.

每次 `snapshot` 也會以 `git ls-remote` 重新確認 authority refs（標準入口是
`origin/main` 與 `origin/prod`）；只相信本地 remote-tracking ref 會把「本地看起來
最新」誤報成目前遠端狀態。傳入 local `main`／`prod` 等未綁定 authority 的 ref 會是
`not_checked` 並使報告 `blocked`。若 remote ref 過期、無法取得或 live backend
version 無法解析到 commit/tree，報告也會 `blocked`；任何依賴該 authority 的
TestFlight→main／production→main precise delta 也必須停止，不得改用已解析的 local SHA 繼續計算。

App Store／TestFlight 的 tuple 比對必須同時有 ASC 的 version、build number 與 build
resource identity，而且兩個 channel 的 `ascBuildId` 必須相等才能視為同一個 binary。
缺少 App Store `READY_FOR_SALE` version 或其 build／identity、或缺少 TestFlight build
binding／identity 時，報告同樣是 `blocked`；identity 不同則明確報告 channel drift，
不可用「最新 TestFlight build」代替使用者實際取得的 App Store 版本。

ASC response 的 `uploadedDate`、build relationship、resource id、build number 與 processing state 都是
必要證據。若最新 iOS build 或 `READY_FOR_SALE` version 的 associated build record
不完整，normalizer 會 fail closed；不可跳過缺少 `uploadedDate` 的 build 再回退到較舊 build。source tag
也不只驗 tag 名稱與 origin SHA：tag target commit 內的 Xcode marketing version／build
tuple 必須與 ASC tuple 相符，否則 source binding 是 `unbound`。

`READY_FOR_SALE` 必須恰好只有一筆；多筆時是 ambiguous，不能自行挑最高版號。
TestFlight 最新 build 只有 `PROCESSING` 或 `VALID` 才是 release-eligible；其他狀態
會 blocked。source tag 也必須同時存在於本地與 `origin`，且 commit 相同；本地私有或
過期 tag 不是 provenance。若明確傳入 `--ipa`，檔案不存在或無法讀取也會使報告
blocked，而不是回傳一個可被自動化誤判為成功的 partial result。

### Provenance contract

「版本」不是一個字串，而是可交叉驗證的 release identity：

```text
iOS = bundle id + marketing version + build number + ASC build id
      + source commit/tree + immutable ios/<version>+<build> tag
      + TestFlight/App Store channel state
backend = source commit/tree + origin/prod + live /api/system/info version
```

Authority 必須保持分離：

| 問題 | Authority | 不可替代的理由 |
|---|---|---|
| iOS build 的 source snapshot | Git `ios/<version>+<build>` tag | ASC 不保留 source commit；缺 tag 就是 `unbound` |
| TestFlight binary/channel | App Store Connect build API | 不可由 local archive、時間戳或版號猜測 |
| App Store user-facing release | App Store Connect `READY_FOR_SALE` version | TestFlight 最新 build 不等於已上架 |
| backend 期望 state | Git `origin/prod` | `main` 不是 production |
| backend 實際 serving state | live `GET /api/system/info` | `origin/prod` 不是 runtime proof |

報告 schema 是 `kg.release.report.v1`；`aligned` 代表證據完整且沒有差異，`drift`
代表證據完整但有可量測差異，`blocked` 代表 anchor 缺失或 external probe 不可用。
exit code `0` 可報告 aligned/drift，exit code `2` 只能報告 partial/blocked。

常見問題的固定讀法：

- 「生產 backend 和 main」看 `backend.productionToMain`（`origin/prod → origin/main`），再看 `backend.production.liveAlignment`。
- 「TestFlight 和 App Store」先比 `ios.testflight`／`ios.appStore` 的 ASC tuple，再比 `ios.appStoreToTestFlight` source diff。
- 「main 和 PR」用 PR 的 exact head 做 `diff --from origin/main --to <pr-head>`；PR open/draft/checks/CR/DS 仍以 GitHub PR 為準，local diff 不代表已 merge。

standalone `diff` 若使用 `origin/<branch>`，會在計算前以 `git ls-remote` 重新驗證
remote SHA；stale、unavailable 或只存在本地的 branch ref 都是 `blocked`。完整 commit
SHA 可作 immutable anchor；tag 則必須同時通過 origin tag binding。這避免本地
remote-tracking ref 或 local branch 被誤報成目前遠端差異。

報告只讀 Git、ASC GET 與 live GET，不建立第二套狀態庫；`--ipa` 只提供本地 IPA
SHA-256，不能宣稱該檔案就是 ASC binary。

## Hard stops

- No production action without explicit release intent and approval.
- No force-push, destructive cleanup or guessed rollback target.
- No claim of release success without current health／store evidence.
- If a required external approval can only be performed by the account owner, report it immediately and continue only with safe parallel work.
