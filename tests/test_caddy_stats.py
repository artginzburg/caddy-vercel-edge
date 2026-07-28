#!/usr/bin/env python3
"""Isolated correctness test for caddy-stats: finalize window, rotation
survival, and no double-counting across the boundary. Pure stdlib."""
import json, os, tempfile
from importlib.machinery import SourceFileLoader
from datetime import datetime, date

# Load the caddy-stats script: prefer the repo copy next to this test, fall
# back to the installed path.
_here = os.path.dirname(os.path.abspath(__file__))
_candidates = [os.path.join(_here, "..", "usr", "local", "bin", "caddy-stats"),
               "/usr/local/bin/caddy-stats"]
_cs_path = next((p for p in _candidates if os.path.exists(p)), _candidates[0])
cs = SourceFileLoader("cs", os.path.abspath(_cs_path)).load_module()

D0 = date(2026, 6, 21)  # "today" (incomplete)
D1 = date(2026, 6, 20)  # yesterday (complete)
D2 = date(2026, 6, 19)  # older (complete)
cs.today_date = lambda: D0  # pin "today" deterministically

def noon_ts(d):
    return datetime(d.year, d.month, d.day, 12, 0, tzinfo=cs.TZ).timestamp()

def write_log(path, records):
    with open(path, "w") as f:
        for host, d, size, bread in records:
            f.write(json.dumps({"ts": noon_ts(d), "size": size, "bytes_read": bread,
                                "request": {"host": host}}) + "\n")

def totals(data):
    out = {}
    for (host, _day), (reqs, byts) in data.items():
        h = out.setdefault(host, [0, 0]); h[0] += reqs; h[1] += byts
    return {h: tuple(v) for h, v in out.items()}

ok = True
def check(label, got, want):
    global ok
    status = "ok " if got == want else "FAIL"
    if got != want: ok = False
    print(f"[{status}] {label}: got={got} want={want}")

with tempfile.TemporaryDirectory() as tmp:
    cs.LOG_DIR = tmp
    cs.DB_DIR = os.path.join(tmp, "db")
    cs.DB_PATH = os.path.join(cs.DB_DIR, "stats.db")

    # Full history present in one log file: A across D2/D1/D0, B across D1/D0.
    log1 = os.path.join(tmp, "access.log")
    write_log(log1, [
        ("a.test", D2, 100, 0),
        ("a.test", D1, 200, 0),
        ("a.test", D0, 300, 0),
        ("b.test", D1, 50, 0),
        ("b.test", D0, 70, 0),
    ])

    check("pre-roll all-time", totals(cs.collect_perday()),
          {"a.test": (3, 600), "b.test": (2, 120)})

    cs.cmd_roll(None)  # finalizes D2 + D1, marker -> D1
    con = cs.db_connect()
    check("marker after roll", cs.get_meta(con, "last_finalized_day"), D1.isoformat())
    con.close()

    check("post-roll all-time (DB D2+D1 merged with live D0)",
          totals(cs.collect_perday()),
          {"a.test": (3, 600), "b.test": (2, 120)})

    # Simulate rotation: D2 and D1 logs aged out; only today's lines remain.
    write_log(log1, [("a.test", D0, 300, 0), ("b.test", D0, 70, 0)])
    check("all-time survives log rotation (DB keeps finalized days)",
          totals(cs.collect_perday()),
          {"a.test": (3, 600), "b.test": (2, 120)})

    cs.cmd_roll(None)  # idempotent: D0 is today, nothing new to finalize
    check("re-roll is idempotent",
          totals(cs.collect_perday()),
          {"a.test": (3, 600), "b.test": (2, 120)})

# ---- visitors: uniqueness across days/hosts, bot/infra filtering, rotation ----
def write_vlog(path, records):
    with open(path, "w") as f:
        for host, d, ip, ua in records:
            f.write(json.dumps({"ts": noon_ts(d), "size": 1, "bytes_read": 0,
                                "request": {"host": host, "client_ip": ip,
                                            "headers": {"User-Agent": [ua]}}}) + "\n")

CHROME = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/138"
SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605 Safari/605"

with tempfile.TemporaryDirectory() as tmp:
    cs.LOG_DIR = tmp
    cs.DB_DIR = os.path.join(tmp, "db")
    cs.DB_PATH = os.path.join(cs.DB_DIR, "stats.db")
    write_vlog(os.path.join(tmp, "access.log"), [
        ("a.test", D2, "1.1.1.1", CHROME),   # human IP1
        ("a.test", D1, "1.1.1.1", CHROME),   # IP1 again, another day
        ("a.test", D1, "2.2.2.2", SAFARI),   # human IP2
        ("a.test", D0, "1.1.1.1", CHROME),   # IP1 today
        ("a.test", D1, "9.9.9.9", "Mozilla/5.0 (compatible; AhrefsBot/7.0)"),  # bot
        ("b.test", D1, "8.8.8.8", "node"),   # app SSR (infra)
        ("b.test", D0, "1.1.1.1", CHROME),   # IP1 on b.test today
    ])
    cs.cmd_roll(None)  # finalize D2,D1 visitors into DB; D0 stays live

    v = cs.collect_visitors()
    per_all, g_all = cs.uniques_by_host(v, lambda d: True)
    check("visitors all-time per host (uniq across days; bot/infra dropped)",
          per_all, {"a.test": 2, "b.test": 1})
    check("visitors all-time global (1.1.1.1 dedup across hosts)", g_all, 2)
    check("visitors on D1 (IP1+IP2; bot excluded)",
          cs.uniques_by_host(v, lambda d: d == D1.isoformat())[0].get("a.test"), 2)
    check("visitors today per host",
          cs.uniques_by_host(v, lambda d: d == D0.isoformat())[0],
          {"a.test": 1, "b.test": 1})

    # rotate away D2/D1 logs; DB must keep finalized visitors
    write_vlog(os.path.join(tmp, "access.log"), [
        ("a.test", D0, "1.1.1.1", CHROME),
        ("b.test", D0, "1.1.1.1", CHROME),
    ])
    check("visitors survive log rotation",
          cs.uniques_by_host(cs.collect_visitors(), lambda d: True)[0],
          {"a.test": 2, "b.test": 1})

print("\nRESULT:", "ALL PASSED" if ok else "FAILURES PRESENT")
raise SystemExit(0 if ok else 1)
