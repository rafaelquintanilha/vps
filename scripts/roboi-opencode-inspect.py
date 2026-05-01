#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import TypeAlias, TypedDict, cast


INSTANCE_ROOT = Path(os.environ.get("ROBOI_INSTANCE_ROOT", "/opt/apps/runtime/roboi-instances"))
LEGACY_APP_DB = Path("/opt/apps/runtime/roboi/data/roboi.db")
LEGACY_OPENCODE_DB = Path("/opt/apps/runtime/roboi/opencode/opencode.db")
ROLES = ("admin", "owner", "operator")
JsonValue: TypeAlias = str | int | float | bool | None | list["JsonValue"] | dict[str, "JsonValue"]
MappingRow: TypeAlias = dict[str, object]


class MessageGroup(TypedDict):
    meta: dict[str, JsonValue]
    created: object
    parts: list[dict[str, JsonValue]]


class CliArgs(argparse.Namespace):
    recent: bool = False
    limit: int = 10
    job_id: str | None = None
    thread_key: str | None = None
    opencode_session_id: str | None = None
    instance: str | None = None
    role: str | None = None


def connect(path: Path) -> sqlite3.Connection:
    if not path.exists():
        raise SystemExit(f"SQLite database not found: {path}")

    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def resolve_app_path(instance: str | None) -> tuple[Path, Path | None]:
    if instance:
        instance_dir = INSTANCE_ROOT / instance
        return instance_dir / "data" / "roboi.db", instance_dir

    if INSTANCE_ROOT.exists():
        instance_dirs = sorted(path.parent for path in INSTANCE_ROOT.glob("*/instance.env"))
        if len(instance_dirs) == 1:
            instance_dir = instance_dirs[0]
            return instance_dir / "data" / "roboi.db", instance_dir
        if len(instance_dirs) > 1:
            names = ", ".join(path.name for path in instance_dirs)
            raise SystemExit(f"Multiple Roboi instances found ({names}); pass --instance <client-id>.")

    return LEGACY_APP_DB, None


def resolve_opencode_path(instance_dir: Path | None, role: str | None) -> Path:
    if instance_dir is None:
        return LEGACY_OPENCODE_DB

    if role:
        if role not in ROLES:
            raise SystemExit(f"Invalid role: {role}")
        return instance_dir / "opencode" / role / "opencode.db"

    legacy_path = instance_dir / "opencode" / "opencode.db"
    if legacy_path.exists():
        return legacy_path

    existing_role_paths = [
        (candidate_role, instance_dir / "opencode" / candidate_role / "opencode.db")
        for candidate_role in ROLES
        if (instance_dir / "opencode" / candidate_role / "opencode.db").exists()
    ]
    if len(existing_role_paths) == 1:
        return existing_role_paths[0][1]

    raise SystemExit("Role-specific OpenCode state found; pass --role admin|owner|operator.")


def connect_optional(path: Path) -> sqlite3.Connection | None:
    if not path.exists():
        return None
    return connect(path)


def fetch_one(
    connection: sqlite3.Connection,
    query: str,
    parameters: tuple[object, ...] = (),
) -> sqlite3.Row | None:
    return cast(sqlite3.Row | None, connection.execute(query, parameters).fetchone())


def fetch_all(
    connection: sqlite3.Connection,
    query: str,
    parameters: tuple[object, ...] = (),
) -> list[sqlite3.Row]:
    return cast(list[sqlite3.Row], connection.execute(query, parameters).fetchall())


def row_value(row: sqlite3.Row, key: str) -> object:
    return cast(object, row[key])


def row_text(row: sqlite3.Row, key: str) -> str | None:
    value = row_value(row, key)
    return value if isinstance(value, str) and value else None


def row_to_mapping(row: sqlite3.Row) -> MappingRow:
    return {key: row_value(row, key) for key in row.keys()}


def mapping_text(row: MappingRow, key: str) -> str | None:
    value = row.get(key)
    return value if isinstance(value, str) and value else None


def parse_object(value: JsonValue | None) -> dict[str, JsonValue]:
    return value if isinstance(value, dict) else {}


def parse_string(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def fmt_ts(value: object) -> str:
    if value is None:
        return "-"
    try:
        if not isinstance(value, (int, float, str)):
            return str(value)
        dt = datetime.fromtimestamp(int(value) / 1000, tz=timezone.utc)
    except Exception:
        return str(value)
    return dt.isoformat()


def parse_json(value: object) -> JsonValue | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return cast(JsonValue, json.loads(value))
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
) -> MappingRow:
    if job_id:
        row = fetch_one(
            app,
            """
            select
              j.id as job_id,
              j.thread_key,
              j.status,
              j.message_text,
              s.opencode_session_id,
              s.title,
              coalesce(j.user_role, s.data_access_role) as data_access_role
            from jobs j
            left join sessions s on s.thread_key = j.thread_key
            where j.id = ?
            """,
            (job_id,),
        )
        if not row:
            raise SystemExit(f"Job not found: {job_id}")
        return row_to_mapping(row)

    if thread_key:
        row = fetch_one(
            app,
            """
            select
              null as job_id,
              s.thread_key,
              null as status,
              null as message_text,
              s.opencode_session_id,
              s.title,
              s.data_access_role
            from sessions s
            where s.thread_key = ?
            """,
            (thread_key,),
        )
        if not row:
            raise SystemExit(f"Thread not found: {thread_key}")
        return row_to_mapping(row)

    if session_id:
        row = fetch_one(
            app,
            """
            select
              null as job_id,
              s.thread_key,
              null as status,
              null as message_text,
              s.opencode_session_id,
              s.title,
              s.data_access_role
            from sessions s
            where s.opencode_session_id = ?
            """,
            (session_id,),
        )
        if row:
            return row_to_mapping(row)
        return {
            "job_id": None,
            "thread_key": None,
            "status": None,
            "message_text": None,
            "opencode_session_id": session_id,
            "title": None,
            "data_access_role": None,
        }

    raise SystemExit("Provide --job-id, --thread-key, or --opencode-session-id")


def list_recent(
    app: sqlite3.Connection,
    instance_dir: Path | None,
    role: str | None,
    limit: int,
) -> None:
    rows = fetch_all(
        app,
        """
        select
          j.id as job_id,
          j.thread_key,
          j.status,
          j.user_role,
          j.message_text,
          j.created_at,
          s.opencode_session_id,
          s.data_access_role,
          s.title
        from jobs j
        left join sessions s on s.thread_key = j.thread_key
        order by j.created_at desc
        limit ?
        """,
        (limit,),
    )

    if not rows:
        print("No jobs found.")
        return

    for row in rows:
        model = "-"
        effective_role = row_text(row, "user_role") or row_text(row, "data_access_role") or role
        opencode_session_id = row_text(row, "opencode_session_id")
        try:
            opencode = connect_optional(resolve_opencode_path(instance_dir, effective_role))
        except SystemExit:
            opencode = None
        if opencode and opencode_session_id:
            message = fetch_one(
                opencode,
                """
                select data
                from message
                where session_id = ?
                order by time_created asc
                limit 1
                """,
                (opencode_session_id,),
            )
            parsed = parse_object(parse_json(row_value(message, "data"))) if message else {}
            model_data = parse_object(parsed.get("model"))
            provider = parse_string(model_data.get("providerID"))
            model_id = parse_string(model_data.get("modelID"))
            if provider and model_id:
                model = f"{provider}/{model_id}"
            elif model_id:
                model = model_id

        job_id = row_text(row, "job_id") or "-"
        status = row_text(row, "status") or "-"
        thread_key = row_text(row, "thread_key") or "-"
        title = row_text(row, "title") or row_text(row, "message_text") or "-"

        print(
            " | ".join(
                [
                    f"job={job_id}",
                    f"status={status}",
                    f"role={effective_role or '-'}",
                    f"thread={thread_key}",
                    f"opencode={opencode_session_id or '-'}",
                    f"model={model}",
                    f"created={fmt_ts(row_value(row, 'created_at'))}",
                    f"title={compact_text(title, 120)}",
                ]
            )
        )


def show_session(opencode: sqlite3.Connection, mapping_row: MappingRow) -> None:
    session_id = mapping_text(mapping_row, "opencode_session_id")
    if not session_id:
        raise SystemExit("No OpenCode session mapping found.")

    session = fetch_one(opencode, "select * from session where id = ?", (session_id,))
    if not session:
        raise SystemExit(f"OpenCode session not found: {session_id}")

    print("Session")
    print(f"  opencode_session_id: {row_text(session, 'id') or '-'}")
    print(f"  thread_key: {mapping_text(mapping_row, 'thread_key') or '-'}")
    print(f"  job_id: {mapping_text(mapping_row, 'job_id') or '-'}")
    print(f"  data_access_role: {mapping_text(mapping_row, 'data_access_role') or '-'}")
    print(f"  title: {row_text(session, 'title') or mapping_text(mapping_row, 'title') or '-'}")
    print(f"  slug: {row_text(session, 'slug') or '-'}")
    print(f"  directory: {row_text(session, 'directory') or '-'}")
    print(f"  created_at: {fmt_ts(row_value(session, 'time_created'))}")
    print(f"  updated_at: {fmt_ts(row_value(session, 'time_updated'))}")
    print()

    rows = fetch_all(
        opencode,
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
    )

    grouped: dict[str, MessageGroup] = {}
    order: list[str] = []
    for row in rows:
        message_id = row_text(row, "message_id")
        if not message_id:
            continue
        if message_id not in grouped:
            meta = parse_object(parse_json(row_value(row, "message_data")))
            grouped[message_id] = {
                "meta": meta,
                "created": row_value(row, "time_created"),
                "parts": [],
            }
            order.append(message_id)
        part_data = parse_object(parse_json(row_value(row, "part_data")))
        if part_data:
            grouped[message_id]["parts"].append(part_data)

    for message_id in order:
        item = grouped[message_id]
        meta = item["meta"]
        role = parse_string(meta.get("role")) or "unknown"
        model = parse_object(meta.get("model"))
        model_str = ""
        provider = parse_string(model.get("providerID"))
        model_id = parse_string(model.get("modelID"))
        if provider or model_id:
            model_str = f" [{provider}/{model_id}]"
        print(f"{fmt_ts(item['created'])} {role}{model_str} {message_id}")

        for part in item["parts"]:
            ptype = parse_string(part.get("type"))
            if ptype == "text":
                text = parse_string(part.get("text")) or ""
                if text:
                    print(f"  text: {compact_text(text, 600)}")
            elif ptype == "tool":
                tool_name = parse_string(part.get("tool")) or "-"
                state = parse_object(part.get("state"))
                title = parse_string(state.get("title")) or "-"
                status = parse_string(state.get("status")) or "-"
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
    _ = parser.add_argument(
        "--recent",
        action="store_true",
        help="List recent jobs and mapped OpenCode sessions.",
    )
    _ = parser.add_argument("--limit", type=int, default=10, help="Number of recent jobs to list.")
    _ = parser.add_argument("--job-id", help="Roboi job ID to inspect.")
    _ = parser.add_argument("--thread-key", help="Roboi thread key to inspect.")
    _ = parser.add_argument("--opencode-session-id", help="OpenCode session ID to inspect directly.")
    _ = parser.add_argument("--instance", help="Roboi instance client id. Required when multiple instances exist.")
    _ = parser.add_argument("--role", choices=ROLES, help="Data-access role runtime to inspect.")
    args = cast(CliArgs, parser.parse_args())

    app_db, instance_dir = resolve_app_path(args.instance)
    app = connect(app_db)

    if args.recent:
        list_recent(app, instance_dir, args.role, max(1, args.limit))
        return 0

    mapping = get_mapping(
        app,
        job_id=args.job_id,
        thread_key=args.thread_key,
        session_id=args.opencode_session_id,
    )
    role = mapping_text(mapping, "data_access_role") or args.role
    opencode_db = resolve_opencode_path(instance_dir, role)
    opencode = connect(opencode_db)
    show_session(opencode, mapping)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
