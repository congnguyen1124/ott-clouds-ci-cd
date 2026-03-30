#!/usr/bin/env python3
import os
import re
import sqlite3
import subprocess
import sys
from hashlib import pbkdf2_hmac


def main() -> int:
    cookie_db = os.environ.get("COOKIE_DB", "")
    host = os.environ.get("BACKLOG_HOST", "")
    if not cookie_db or not host:
        return 1

    try:
        secret = subprocess.check_output(
            ["security", "find-generic-password", "-w", "-a", "Chrome", "-s", "Chrome Safe Storage"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return 1

    if not secret:
        return 1

    key_hex = pbkdf2_hmac("sha1", secret.encode("utf-8"), b"saltysalt", 1003, 16).hex()
    iv_hex = "20" * 16

    try:
        conn = sqlite3.connect(cookie_db)
        cur = conn.cursor()
    except Exception:
        return 1

    domain = host.split(".", 1)[1] if "." in host else host
    try:
        rows = cur.execute(
            """
            select hex(encrypted_value)
            from cookies
            where name='PLAY_SESSION'
              and host_key in (?, ?)
            order by expires_utc desc
            """,
            (host, f".{domain}"),
        ).fetchall()
    except Exception:
        return 1
    finally:
        conn.close()

    if not rows:
        return 1

    jwt_pattern = re.compile(r"eyJhbGciOiJIUzI1NiJ9\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")

    for row in rows:
        hexv = row[0] or ""
        if not (hexv.startswith("763130") or hexv.startswith("763131")):
            continue

        try:
            encrypted = bytes.fromhex(hexv[6:])
        except ValueError:
            continue

        proc = subprocess.run(
            ["openssl", "enc", "-d", "-aes-128-cbc", "-K", key_hex, "-iv", iv_hex, "-nopad"],
            input=encrypted,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        decrypted = proc.stdout or b""
        if not decrypted:
            continue

        pad = decrypted[-1]
        if 1 <= pad <= 16:
            decrypted = decrypted[:-pad]

        candidates = [decrypted]
        if len(decrypted) > 32:
            candidates.append(decrypted[32:])

        for candidate in candidates:
            text = candidate.decode("utf-8", "ignore")
            matched = jwt_pattern.search(text)
            if matched:
                sys.stdout.write(matched.group(0))
                return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
