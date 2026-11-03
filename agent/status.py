#!/usr/bin/env python3
"""Write the agent's status (status.json, report.md, README.md) for the agent-status branch."""
import argparse
import datetime
import json
import socket
import subprocess
from pathlib import Path


def gh_json(args):
    try:
        return json.loads(subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60, check=True).stdout)
    except Exception:
        return None


def tail(path, n):
    try:
        return path.read_text(errors="replace").splitlines()[-n:]
    except OSError:
        return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--owner", required=True)
    ap.add_argument("--cap", type=int, required=True)
    a = ap.parse_args()
    s = a.state
    today = datetime.date.today().isoformat()

    prs = gh_json(["pr", "list", "--repo", a.upstream, "--author", a.owner, "--state", "all", "--limit", "40",
                   "--json", "number,title,state,headRefName,reviewDecision,mergeable,isDraft,updatedAt,url"]) or []
    pr_by_branch = {p["headRefName"]: p for p in prs}

    ready = []
    for d in sorted((s / "ready").glob("*")):
        task = json.loads((d / "task.json").read_text()) if (d / "task.json").exists() else {}
        branch = d.name.replace("_", "/", 1)
        title = ((d / "commit.txt").read_text().splitlines() or [""])[0] if (d / "commit.txt").exists() else ""
        pr = pr_by_branch.get(branch)
        ready.append({
            "branch": branch, "title": title, "library": task.get("library"), "functions": task.get("functions", []),
            "issues": task.get("issues", []), "pushed": datetime.datetime.fromtimestamp(d.stat().st_mtime).isoformat(timespec="minutes"),
            "pr": pr and {"number": pr["number"], "state": pr["state"], "url": pr["url"]},
            "compare": f"https://github.com/{a.owner}/AnyPS5/compare/main...{branch}?expand=1",
            "pr_command": f'gh pr create --repo {a.upstream} --head {a.owner}:{branch} --title "{title}" --body-file {d / "pr.md"}',
        })

    needs_you = []
    for d in sorted((s / "followup").glob("*")):
        if (d / "reply.md").exists():
            needs_you.append({"pr": int(d.name), "kind": "reply", "text": (d / "reply.md").read_text()[:3000]})
        if (d / "failure.md").exists():
            needs_you.append({"pr": int(d.name), "kind": "followup-failed", "text": (d / "failure.md").read_text()[:2000]})

    log = tail(s / "agent.log", 60)
    control = json.loads((s / "control.json").read_text()) if (s / "control.json").exists() else {}
    status = {
        "updated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="minutes"),
        "host": socket.gethostname(),
        "paused": (s / "PAUSE").exists() or bool(control.get("paused")),
        "today": {"date": today, "pushed": int((s / f"count-{today}").read_text()) if (s / f"count-{today}").exists() else 0, "cap": a.cap},
        "activity": log[-1] if log else "no log yet",
        "baseline_failures": len(tail(s / "baseline-failures.txt", 10000)),
        "done": len(tail(s / "done.txt", 100000)),
        "skipped": len(tail(s / "skip.txt", 100000)),
        "recent_skips": tail(s / "skip.txt", 10),
        "prs": prs,
        "ready": ready,
        "needs_you": needs_you,
        "log": log,
        "control_seen": control,
    }
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "status.json").write_text(json.dumps(status, indent=1))
    (a.out / "report.md").write_text("\n".join(tail(s / "report.md", 400)) + "\n")
    (a.out / "README.md").write_text(
        f"# AnyPS5 agent status\n\nUpdated {status['updated']} from `{status['host']}`. "
        f"Pushed today: {status['today']['pushed']}/{a.cap}. Ready branches: {len(ready)}. Needs you: {len(needs_you)}.\n\n"
        f"Last activity: `{status['activity']}`\n\nWritten by the VPS agent; the captain reads `status.json`. Don't edit by hand.\n")


if __name__ == "__main__":
    main()
