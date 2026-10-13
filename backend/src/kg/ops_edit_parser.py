"""Parser assembly for the write-capable ops tool."""

from __future__ import annotations

import argparse
import sys

from .ops_edit_commands import (
    _VALID_REVIEW_STATES,
    cmd_card_add,
    cmd_card_delete,
    cmd_card_import,
    cmd_card_move,
    cmd_card_set_review,
    cmd_card_update,
    cmd_clone_demo,
    cmd_link_add,
    cmd_link_delete,
    cmd_link_list,
    cmd_link_update,
    cmd_list_backups,
    cmd_notebook_create,
    cmd_notebook_delete,
    cmd_notebook_update,
    cmd_restore,
    cmd_seed,
    cmd_user_config_set,
    cmd_user_create,
    cmd_user_delete,
    cmd_world_restore,
    cmd_world_snapshot,
)
from .ops_edit_shared import EditError, emit
from .sentry_init import init_sentry


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ops_edit.py",
        description="KG production 資料**寫入**工具(dry-run 預設)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    jp = argparse.ArgumentParser(add_help=False)
    jp.add_argument("--json", action="store_true", help="以 JSON 輸出")
    cp = argparse.ArgumentParser(add_help=False)
    cp.add_argument("--commit", action="store_true", help="真正寫入(預設 dry-run 只印 plan)")

    p = sub.add_parser("user-create", parents=[jp, cp], help="建立用戶 + 預設筆記本")
    p.add_argument("uid")
    p.add_argument("--email")
    p.add_argument("--provider", default="google", choices=["google", "apple", "demo"])
    p.add_argument("--allow-existing", action="store_true", help="user 已存在時 merge record")
    p.add_argument("--reassign-email", action="store_true", help="email 已屬他人 uid 時仍改指向本 uid(預設拒絕)")
    p.set_defaults(func=cmd_user_create)

    p = sub.add_parser(
        "user-delete",
        parents=[jp, cp],
        help="刪除用戶(移除 user dir + users.json record + email/subscription index;寫前自動備份,可 restore)",
    )
    p.add_argument("uid")
    p.set_defaults(func=cmd_user_delete)

    p = sub.add_parser("card-add", parents=[jp, cp], help="新增單字卡")
    p.add_argument("uid")
    p.add_argument("content")
    p.add_argument("--meaning", required=True)
    p.add_argument("--pos")
    p.add_argument("--example", action="append", help="例句(可重複)")
    p.add_argument("--collocation", action="append", help="搭配(可重複)")
    p.add_argument("--note")
    p.add_argument("--difficulty", type=float)
    p.add_argument("--mode", default="recognition", choices=["recognition", "production"])
    p.add_argument("--notebook", default="default")
    p.add_argument("--review", choices=list(_VALID_REVIEW_STATES))
    p.add_argument("--interval", type=float, help="複習間隔(小時)")
    p.set_defaults(func=cmd_card_add)

    p = sub.add_parser("card-update", parents=[jp, cp], help="改卡欄位(--set field=value)")
    p.add_argument("uid")
    p.add_argument("card", help="card id 或 content")
    p.add_argument("--set", action="append", help="field=value(value 走 JSON 解析;可重複)")
    p.set_defaults(func=cmd_card_update)

    p = sub.add_parser("card-set-review", parents=[jp, cp], help="設複習態(new/due/reviewed)")
    p.add_argument("uid")
    p.add_argument("card", help="card id 或 content")
    p.add_argument("--state", required=True, choices=list(_VALID_REVIEW_STATES))
    p.add_argument("--interval", type=float)
    p.set_defaults(func=cmd_card_set_review)

    p = sub.add_parser("card-delete", parents=[jp, cp], help="軟刪單字卡")
    p.add_argument("uid")
    p.add_argument("card", help="card id 或 content")
    p.set_defaults(func=cmd_card_delete)

    p = sub.add_parser("card-import", parents=[jp, cp], help="CSV 批量匯入(card_format.md 格式)")
    p.add_argument("uid")
    p.add_argument("csv", help="CSV 檔路徑")
    p.add_argument("--notebook", default="default")
    p.set_defaults(func=cmd_card_import)

    p = sub.add_parser("notebook-create", parents=[jp, cp], help="建立筆記本")
    p.add_argument("uid")
    p.add_argument("name")
    p.add_argument("--color")
    p.add_argument("--cover", help="cover_pattern")
    p.set_defaults(func=cmd_notebook_create)

    p = sub.add_parser(
        "user-config-set", parents=[jp, cp], help="更新 user config(translation/review clock/mode/vocab UI)"
    )
    p.add_argument("uid")
    p.add_argument("--translation-source")
    p.add_argument("--translation-target")
    p.add_argument("--review-clock", choices=["paused", "running"])
    p.add_argument("--paused-at", help="ISO datetime;僅搭配 --review-clock paused")
    p.add_argument("--review-mode", choices=["relaxed", "intensive", "custom"])
    p.add_argument("--custom-initial-interval-hours", type=float)
    p.add_argument("--custom-remembered-multiplier", type=float)
    p.add_argument("--custom-forgot-multiplier", type=float)
    p.add_argument("--custom-minimum-interval-hours", type=float)
    p.add_argument("--custom-maximum-interval-hours", type=float)
    p.add_argument("--active-notebook", help="notebook id 或 name")
    p.add_argument("--auto-link", choices=["on", "off"], help="judge pipeline 自動連結開關")
    p.set_defaults(func=cmd_user_config_set)

    p = sub.add_parser("link-add", parents=[jp, cp], help="連結兩張卡(知識圖譜)")
    p.add_argument("uid")
    p.add_argument("from_ref", metavar="from", help="來源 card id 或 content")
    p.add_argument("to_ref", metavar="to", help="目標 card id 或 content")
    p.add_argument("--kind", required=True, choices=["contrasts_with", "shares_usage"])
    p.add_argument("--confidence", type=float, required=True)
    p.add_argument("--reason", required=True)
    p.add_argument("--notebook", default="default")
    p.add_argument(
        "--if-exists",
        choices=["keep", "update"],
        default="keep",
        help="既有 pair 存在時：keep=維持既有值(預設)；update=改寫 confidence/kind/reason",
    )
    p.set_defaults(func=cmd_link_add)

    p = sub.add_parser("link-delete", parents=[jp, cp], help="硬刪一條連結")
    p.add_argument("uid")
    p.add_argument("link_id")
    p.add_argument("--notebook", default="default")
    p.set_defaults(func=cmd_link_delete)

    p = sub.add_parser("seed", parents=[jp, cp], help="一次性灌整套 demo(notebooks+cards+links)")
    p.add_argument("uid")
    p.add_argument("spec", help="seed spec JSON 檔路徑")
    p.add_argument(
        "--replace", action="store_true", help="先清空目標帳號整層 vocab 再灌;spec 即最終狀態,identity(users.json)不動"
    )
    p.set_defaults(func=cmd_seed)

    p = sub.add_parser(
        "clone-demo", parents=[jp, cp], help="高保真複製來源帳號 vocab 層到目標 demo 帳號 + 合成 review history"
    )
    p.add_argument("source_uid", help="來源帳號 uid(讀取,不變更)")
    p.add_argument("target_uid", help="目標 demo 帳號 uid(覆蓋 vocab 層;identity 不動)")
    p.add_argument("--expect-source-fingerprint", help="要求來源 vocab 層指紋相符，避免來源漂移導致 clone 結果改變")
    p.set_defaults(func=cmd_clone_demo)

    p = sub.add_parser(
        "world-snapshot", parents=[jp, cp], help="建立整個 data_dir world snapshot（users.json + users/* + 根目錄 DB）"
    )
    p.add_argument("--label", default="world")
    p.set_defaults(func=cmd_world_snapshot)

    p = sub.add_parser("world-restore", parents=[jp, cp], help="從 world snapshot 還原整個 data_dir")
    p.add_argument("--snapshot", help="指定 snapshot tar.gz（預設取最新）")
    p.set_defaults(func=cmd_world_restore)

    p = sub.add_parser("list-backups", parents=[jp], help="列出某 uid 的自動備份(最新在前)")
    p.add_argument("uid")
    p.set_defaults(func=cmd_list_backups)

    p = sub.add_parser("restore", parents=[jp, cp], help="從備份還原 user_dir(預設取最新)")
    p.add_argument("uid")
    p.add_argument("--backup", help="指定備份 tar.gz 路徑(預設取最新)")
    p.set_defaults(func=cmd_restore)

    p = sub.add_parser("notebook-update", parents=[jp, cp], help="改筆記本 name/color/cover")
    p.add_argument("uid")
    p.add_argument("notebook", help="notebook id 或 name")
    p.add_argument("--name")
    p.add_argument("--color")
    p.add_argument("--cover", help="cover_pattern")
    p.add_argument("--sort-order", type=int)
    p.set_defaults(func=cmd_notebook_update)

    p = sub.add_parser("notebook-delete", parents=[jp, cp], help="軟刪筆記本(default 不可刪)")
    p.add_argument("uid")
    p.add_argument("notebook", help="notebook id 或 name")
    p.add_argument("--cascade", action="store_true", help="一併軟刪該本所有卡(否則非空時拒絕,避免孤兒卡)")
    p.set_defaults(func=cmd_notebook_delete)

    p = sub.add_parser("card-move", parents=[jp, cp], help="把卡移到別的筆記本")
    p.add_argument("uid")
    p.add_argument("card", help="card id 或 content")
    p.add_argument("--to-notebook", "--notebook", dest="to_notebook", required=True, help="目標 notebook id 或 name")
    p.set_defaults(func=cmd_card_move)

    p = sub.add_parser("link-list", parents=[jp], help="列出某 notebook 的連結(id+兩端 content)")
    p.add_argument("uid")
    p.add_argument("--notebook", default="default")
    p.set_defaults(func=cmd_link_list)

    p = sub.add_parser("link-update", parents=[jp, cp], help="改連結 confidence/reason/kind")
    p.add_argument("uid")
    p.add_argument("link_id")
    p.add_argument("--confidence", type=float)
    p.add_argument("--reason")
    p.add_argument("--kind", choices=["contrasts_with", "shares_usage"])
    p.add_argument("--notebook", default="default")
    p.set_defaults(func=cmd_link_update)

    return parser


def main() -> None:
    init_sentry(job="ops_edit")
    args = build_parser().parse_args()
    try:
        code = args.func(args)
    except EditError as exc:
        emit(
            {"mode": "error", "action": args.cmd, "error": str(exc), "committed": False},
            json_mode=getattr(args, "json", False),
        )
        sys.exit(1)
    sys.exit(code or 0)
