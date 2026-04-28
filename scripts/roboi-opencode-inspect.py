#!/usr/bin/env python3
import argparse
import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


INSTANCE_ROOT = Path(os.environ.get("ROBOI_INSTANCE_ROOT", "/opt/apps/runtime/roboi-instances"))
LEGACY_APP_DB = Path("/opt/apps/runtime/roboi/data/roboi.db")
LEGACY_OPENCODE_DB = Path("/opt/apps/runtime/roboi/opencode/opencode.db")


def connect(path: Path) -> sqlite3.Connection:
    if not path.exists():
        raise SystemExit(f"SQLite database not found: {path}")

    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def resolve_db_paths(instance: str | None) -> tuple[Path, Path]:
    if instance:
        instance_dir = INSTANCE_ROOT / instance
        return instance_dir / "data" / "roboi.db", instance_dir / "opencode" / "opencode.db"

    if INSTANCE_ROOT.exists():
        instance_dirs = sorted(path.parent for path in INSTANCE_ROOT.glob("*/instance.env"))
        if len(instance_dirs) == 1:
            instance_dir = instance_dirs[0]
            return instance_dir / "data" / "roboi.db", instance_dir / "opencode" / "opencode.db"
        if len(instance_dirs) > 1:
            names = ", ".join(path.name for path in instance_dirs)
            raise SystemExit(f"Multiple Roboi instances found ({names}); pass --instance <client-id>.")

    return LEGACY_APP_DB, LEGACY_OPENCODE_DB


def fmt_ts(value: Any) -> str:
    if value is None:
        return "-"
    try:
        dt = datetime.fromtimestamp(int(value) / 1000, tz=timezone.utc)
    except Exception:
        return str(value)
    return dt.isoformat()


def parse_json(value: Any) -> Any:
    if not isinstance(value, str) or not value:
        return None
    try:
        return json.loads(value)
    except Exception:
        return None


def compact_text(value: str, limit: int = 240) -> str:
    text = " ".join(value.split())
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def get_mapping(
    app: sqlite3.Connection,
    *,
    job_id: str | None,
    thread_key: str | None,
    session_id: str | None,
) -> dict[str, Any]:
    if job_id:
        row = app.execute(
            """
            select j.id as job_id, j.thread_key, j.status, j.message_text, s.opencode_session_id, s.title
            from jobs j
            left join sessions s on s.thread_key = j.thread_key
            where j.id = ?
            """,
            (job_id,),
        ).fetchone()
        if not row:
            raise SystemExit(f"Job not found: {job_id}")
        return dict(row)

    if thread_key:
        row = app.execute(
            """
            select null as job_id, s.thread_key, null as status, null as message_text, s.opencode_session_id, s.title
            from sessions s
            where s.thread_key = ?
            """,
            (thread_key,),
        ).fetchone()
        if not row:
            raise SystemExit(f"Thread not found: {thread_key}")
        return dict(row)

    if session_id:
        row = app.execute(
            """
            select null as job_id, s.thread_key, null as status, null as message_text, s.opencode_session_id, s.title
            from sessions s
            where s.opencode_session_id = ?
            """,
            (session_id,),
        ).fetchone()
        if row:
            return dict(row)
        return {
            "job_id": None,
            "thread_key": None,
            "status": None,
            "message_text": None,
            "opencode_session_id": session_id,
            "title": None,
        }

    raise SystemExit("Provide --job-id, --thread-key, or --opencode-session-id")


def list_recent(app: sqlite3.Connection, opencode: sqlite3.Connection, limit: int):
    rows = app.execute(
        """
        select
          j.id as job_id,
          j.thread_key,
          j.status,
          j.message_text,
          j.created_at,
          s.opencode_session_id,
          s.title
        from jobs j
        left join sessions s on s.thread_key = j.thread_key
        order by j.created_at desc
        limit ?
        """,
        (limit,),
    ).fetchall()

    if not rows:
        print("No jobs found.")
        return

    for row in rows:
        model = "-"
        if row["opencode_session_id"]:
            message = opencode.execute(
                """
                select data
                from message
                where session_id = ?
                order by time_created asc
                limit 1
                """,
                (row["opencode_session_id"],),
            ).fetchone()
            parsed = parse_json(message["data"]) if message else None
            provider = (parsed or {}).get("model", {}).get("providerID")
            model_id = (parsed or {}).get("model", {}).get("modelID")
            if provider and model_id:
                model = f"{provider}/{model_id}"
            elif model_id:
                model = str(model_id)

        print(
            " | ".join(
                [
                    f"job={row['job_id']}",
                    f"status={row['status']}",
                    f"thread={row['thread_key']}",
                    f"opencode={row['opencode_session_id'] or '-'}",
                    f"model={model}",
                    f"created={fmt_ts(row['created_at'])}",
                    f"title={compact_text(row['title'] or row['message_text'] or '-', 120)}",
                ]
            )
        )


def show_session(opencode: sqlite3.Connection, mapping_row: dict[str, Any]):
    session_id = mapping_row["opencode_session_id"]
    if not session_id:
        raise SystemExit("No OpenCode session mapping found.")

    session = opencode.execute("select * from session where id = ?", (session_id,)).fetchone()
    if not session:
        raise SystemExit(f"OpenCode session not found: {session_id}")

    print("Session")
    print(f"  opencode_session_id: {session['id']}")
    print(f"  thread_key: {mapping_row.get('thread_key') or '-'}")
    print(f"  job_id: {mapping_row.get('job_id') or '-'}")
    print(f"  title: {session['title'] or mapping_row.get('title') or '-'}")
    print(f"  slug: {session['slug'] or '-'}")
    print(f"  directory: {session['directory'] or '-'}")
    print(f"  created_at: {fmt_ts(session['time_created'])}")
    print(f"  updated_at: {fmt_ts(session['time_updated'])}")
    print()

    rows = opencode.execute(
        """
        select
          m.id as message_id,
          m.time_created,
          m.data as message_data,
          p.data as part_data
        from message m
        left join part p on p.message_id = m.id
        where m.session_id = ?
        order by m.time_created asc, p.time_created asc, p.id asc
        """,
        (session_id,),
    ).fetchall()

    grouped: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for row in rows:
        message_id = row["message_id"]
        if message_id not in grouped:
            meta = parse_json(row["message_data"]) or {}
            grouped[message_id] = {
                "meta": meta,
                "created": row["time_created"],
                "parts": [],
            }
            order.append(message_id)
        part_data = parse_json(row["part_data"])
        if part_data is not None:
            grouped[message_id]["parts"].append(part_data)

    for message_id in order:
        item = grouped[message_id]
        meta = item["meta"]
        role = meta.get("role") or "unknown"
        model = meta.get("model") or {}
        model_str = ""
        if isinstance(model, dict):
            provider = model.get("providerID")
            model_id = model.get("modelID")
            if provider or model_id:
                model_str = f" [{provider}/{model_id}]"
        print(f"{fmt_ts(item['created'])} {role}{model_str} {message_id}")

        for part in item["parts"]:
            ptype = part.get("type")
            if ptype == "text":
                text = str(part.get("text") or "").strip()
                if text:
                    print(f"  text: {compact_text(text, 600)}")
            elif ptype == "tool":
                tool_name = part.get("tool") or "-"
                state = part.get("state") or {}
                title = state.get("title") or "-"
                status = state.get("status") or "-"
                print(f"  tool: {tool_name} | title={title} | status={status}")
                if part.get("input") is not None:
                    print(f"    input: {compact_text(json.dumps(part.get('input'), ensure_ascii=False), 600)}")
                if part.get("output") is not None:
                    print(f"    output: {compact_text(json.dumps(part.get('output'), ensure_ascii=False), 600)}")
            else:
                print(f"  part[{ptype or 'unknown'}]: {compact_text(json.dumps(part, ensure_ascii=False), 600)}")
        print()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inspect Roboi/OpenCode sessions on the VPS.",
    )
    parser.add_argument("--recent", action="store_true", help="List recent jobs and mapped OpenCode sessions.")
    parser.add_argument("--limit", type=int, default=10, help="Number of recent jobs to list.")
    parser.add_argument("--job-id", help="Roboi job ID to inspect.")
    parser.add_argument("--thread-key", help="Roboi thread key to inspect.")
    parser.add_argument("--opencode-session-id", help="OpenCode session ID to inspect directly.")
    parser.add_argument("--instance", help="Roboi instance client id. Required when multiple instances exist.")
    args = parser.parse_args()

    app_db, opencode_db = resolve_db_paths(args.instance)
    app = connect(app_db)
    opencode = connect(opencode_db)

    if args.recent:
        list_recent(app, opencode, max(1, args.limit))
        return 0

    mapping = get_mapping(
        app,
        job_id=args.job_id,
        thread_key=args.thread_key,
        session_id=args.opencode_session_id,
    )
    show_session(opencode, mapping)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
