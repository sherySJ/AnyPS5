#!/usr/bin/env python3
"""Rank unimplemented AnyPS5 exports for the scout.

Signals, in order of weight:
  1. named in an open upstream issue (a title needs it)
  2. its library had PRs merged recently (maintainers are active there)
  3. its library is nearly done (small gaps merge faster)
Excluded: unknown NIDs, anything an open upstream PR already touches,
anything this agent already did or gave up on.
"""
import argparse
import json
import re
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

UPSTREAM = "boykopovar/AnyPS5"
SKIP_LIBS = {"libSceNKWebKit", "libSceAddressSanitizer", "libwebrtc", "libcairo", "libSceJsc", "libmdbg_syscore"}
LIB_PATH = re.compile(r"core/libs/prx/([^/]+)/")
EXPORT_LINE = re.compile(r"\bAPS5_VABI\s+(\w+)\s*\(")
WORD = re.compile(r"\b[A-Za-z_]\w{5,}\b")


def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=True).stdout


def gh_json(args):
    return json.loads(run(["gh", *args]))


def cached(path, max_age, producer):
    if path.exists() and time.time() - path.stat().st_mtime < max_age:
        return json.loads(path.read_text())
    data = producer()
    path.write_text(json.dumps(data))
    return data


def in_flight_names(repo, prs):
    run(["git", "fetch", "-q", "upstream", "+refs/pull/*/head:refs/upstream-pr/*"], cwd=repo)
    names = set()
    for pr in prs:
        ref = f"refs/upstream-pr/{pr['number']}"
        try:
            diff = run(["git", "diff", "-U0", f"upstream/main...{ref}", "--", "core/libs/prx"], cwd=repo)
        except subprocess.CalledProcessError:
            continue
        for line in diff.splitlines():
            if line.startswith("+") or line.startswith("@@"):
                names.update(EXPORT_LINE.findall(line))
        names.update(WORD.findall(pr["title"]))
    return sorted(names)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, required=True)
    ap.add_argument("--state", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--top", type=int, default=40)
    a = ap.parse_args()
    cache = a.state / "cache"
    cache.mkdir(parents=True, exist_ok=True)

    progress = json.loads(run([sys.executable, "tools/progress.py", "--json"], cwd=a.repo))["libraries"]

    prs = cached(cache / "open_prs.json", 6 * 3600, lambda: gh_json(
        ["pr", "list", "--repo", UPSTREAM, "--state", "open", "--limit", "1000", "--json", "number,title,headRefName"]))
    busy = set(cached(cache / "in_flight.json", 6 * 3600, lambda: in_flight_names(a.repo, prs)))

    issues = cached(cache / "issues.json", 6 * 3600, lambda: gh_json(
        ["issue", "list", "--repo", UPSTREAM, "--state", "open", "--limit", "1000", "--json", "number,title,body"]))
    merged = cached(cache / "merged.json", 24 * 3600, lambda: gh_json(
        ["pr", "list", "--repo", UPSTREAM, "--state", "merged", "--limit", "300", "--json", "number,files"]))

    activity = Counter()
    for pr in merged:
        for lib in {m.group(1) for f in pr.get("files", []) for m in [LIB_PATH.search(f["path"])] if m}:
            activity[lib] += 1

    mentions = {}
    for issue in issues:
        for word in set(WORD.findall(f"{issue['title']}\n{issue.get('body') or ''}")):
            mentions.setdefault(word, []).append(issue["number"])

    excluded = set()
    for name in ("done.txt", "skip.txt"):
        p = a.state / name
        if p.exists():
            excluded.update(x.split()[0] for x in p.read_text().split("\n") if x.strip())

    control = {}
    if (a.state / "control.json").exists():
        try:
            control = json.loads((a.state / "control.json").read_text())
        except ValueError:
            pass
    focus = set(control.get("focus", []))
    excluded.update(control.get("skip", []))
    skip_libs = SKIP_LIBS | set(control.get("skip_libraries", []))

    rows = []
    for g in progress["groups"]:
        lib = g["name"]
        if lib in skip_libs:
            continue
        todo = [n for n in g["todo_names"] if "Unknown" not in n]
        total = g["done"] + len(g["todo_names"])
        done_ratio = g["done"] / total if total else 0
        for name in todo:
            base = re.sub(r"_nid_\w+$", "", name)
            if name in excluded or base in busy or name in busy:
                continue
            issue_nums = mentions.get(base, [])[:5]
            boost = 500 if (name in focus or base in focus or lib in focus) else 0
            score = boost + 100 * bool(issue_nums) + 10 * min(activity[lib], 3) + 20 * done_ratio + 10 / (1 + len(todo))
            rows.append({"library": lib, "function": name, "score": round(score, 1), "issues": issue_nums,
                         "library_done": g["done"], "library_todo": len(todo), "recent_merges": activity[lib], "captain_focus": bool(boost)})

    rows.sort(key=lambda r: -r["score"])
    total = len(rows)
    rows = rows[:a.top]
    by_number = {i["number"]: i for i in issues}
    for r in rows:
        r["issue_text"] = [{"number": n, "title": by_number[n]["title"], "body": (by_number[n].get("body") or "")[:1500]}
                           for n in r["issues"][:2]]
    a.out.write_text(json.dumps(rows, indent=1))
    print(f"{total} candidates, {len(busy)} names in open PRs, wrote top {min(a.top, len(rows))}")


if __name__ == "__main__":
    main()
