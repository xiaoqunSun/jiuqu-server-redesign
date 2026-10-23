#!/usr/bin/env python3
"""Generate SQL for one locally authorized client token.

The token is read from stdin so it does not appear in shell history or argv.
Only its keyed HMAC fingerprint is included in the generated SQL.
"""

import argparse
import hashlib
import hmac
import os
import sys


def mysql_binary(value: str) -> str:
    """Encode UTF-8 data as a binary SQL literal without SQL interpolation."""
    return "X'" + value.encode("utf-8").hex() + "'"


def nonnegative_int(value: str) -> int:
    try:
        parsed = int(value, 10)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError("must not be negative")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity-id", required=True)
    parser.add_argument("--room-id", required=True)
    parser.add_argument("--root-room-id")
    parser.add_argument("--is-master", action="store_true")
    parser.add_argument("--begin-at", type=nonnegative_int, default=0)
    parser.add_argument("--expires-at", type=nonnegative_int)
    parser.add_argument("--chat-channel", action="append", default=[],
                        help="extra authorized chat channel; may be repeated")
    parser.add_argument("--sub-room", action="append", default=[],
                        help="authorized sub-room id or alias; may be repeated")
    args = parser.parse_args()

    root_room_id = args.root_room_id or args.room_id
    if not args.identity_id or not args.room_id or not root_room_id:
        parser.error("identity, room, and root room ids must be non-empty")
    if len(args.identity_id.encode("utf-8")) > 255:
        parser.error("identity id exceeds the 255-byte database limit")
    if len(args.room_id.encode("utf-8")) > 191 or len(root_room_id.encode("utf-8")) > 191:
        parser.error("room id exceeds the 191-byte database limit")
    if any(not channel or len(channel.encode("utf-8")) > 128 for channel in args.chat_channel):
        parser.error("chat channels must contain 1 to 128 UTF-8 bytes")
    if any(not sub_room or len(sub_room.encode("utf-8")) > 191 for sub_room in args.sub_room):
        parser.error("sub-room ids must contain 1 to 191 UTF-8 bytes")
    if len(set(args.sub_room)) > 128:
        parser.error("at most 128 sub-rooms may be authorized per token")

    pepper = os.environ.get("AUTH_TOKEN_PEPPER", "").encode("utf-8")
    if len(pepper) < 32:
        parser.error("AUTH_TOKEN_PEPPER must contain at least 32 bytes")

    token = sys.stdin.buffer.read().rstrip(b"\r\n")
    if not token:
        parser.error("read a non-empty access token from stdin")

    token_hash = hmac.new(pepper, token, hashlib.sha1).hexdigest()
    expires_at = "NULL" if args.expires_at is None else str(args.expires_at)
    master = 1 if args.is_master else 0
    statements = [
        "START TRANSACTION;",
        "INSERT INTO access_tokens "
        "(token_hash, identity_id, room_id, root_room_id, is_master, begin_at, expires_at, revoked_at, created_ts) "
        f"VALUES ('{token_hash}', {mysql_binary(args.identity_id)}, {mysql_binary(args.room_id)}, "
        f"{mysql_binary(root_room_id)}, {master}, {args.begin_at}, {expires_at}, NULL, UNIX_TIMESTAMP()) "
        "ON DUPLICATE KEY UPDATE identity_id=VALUES(identity_id), root_room_id=VALUES(root_room_id), "
        "is_master=VALUES(is_master), begin_at=VALUES(begin_at), expires_at=VALUES(expires_at), revoked_at=NULL;",
        f"DELETE FROM access_token_chat_channels WHERE token_hash='{token_hash}' "
        f"AND room_id={mysql_binary(args.room_id)};",
        f"DELETE FROM access_token_sub_rooms WHERE token_hash='{token_hash}' "
        f"AND room_id={mysql_binary(args.room_id)};",
    ]
    for channel in dict.fromkeys(args.chat_channel):
        statements.append(
            "INSERT INTO access_token_chat_channels (token_hash, room_id, channel, created_ts) "
            f"VALUES ('{token_hash}', {mysql_binary(args.room_id)}, {mysql_binary(channel)}, UNIX_TIMESTAMP());"
        )
    for sub_room in dict.fromkeys(args.sub_room):
        statements.append(
            "INSERT INTO access_token_sub_rooms (token_hash, room_id, sub_room, created_ts) "
            f"VALUES ('{token_hash}', {mysql_binary(args.room_id)}, {mysql_binary(sub_room)}, UNIX_TIMESTAMP());"
        )
    statements.append("COMMIT;")
    sys.stdout.write("\n".join(statements) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
