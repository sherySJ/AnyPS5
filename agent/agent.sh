#!/usr/bin/env bash
# AnyPS5 contribution loop: follow up on open PRs, then scout -> implement -> check -> review -> push to fork.
set -uo pipefail
AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$AGENT_DIR/config.sh"
STATE="$AGENT_DIR/state"
LOG="$STATE/agent.log"
REPORT="$STATE/report.md"
UPSTREAM=boykopovar/AnyPS5
mkdir -p "$STATE"/{runs,tasks,ready,followup,cache}
touch "$STATE/done.txt" "$STATE/skip.txt" "$REPORT"

exec 9>"$STATE/.lock"
flock -n 9 || { echo "another agent.sh is already running"; exit 1; }

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
today() { date +%F; }
count_today() { cat "$STATE/count-$(today)" 2>/dev/null || echo 0; }
bump_today() { echo $(( $(count_today) + 1 )) > "$STATE/count-$(today)"; }
report() { printf '%s\n' "$@" >> "$REPORT"; }

# Captain settings from the agent-control branch (state/control.json), with defaults.
ctl() {
  python3 - "$STATE/control.json" "$1" "$2" <<'EOF2'
import json, sys
try:
    value = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    value = None
print(sys.argv[3] if value is None else (str(value).lower() if isinstance(value, bool) else value))
EOF2
}
cap() { ctl daily_cap "$DAILY_CAP"; }
paused() { [ -f "$STATE/PAUSE" ] || [ "$(ctl paused false)" = true ]; }

# Pull the captain's control.json and, when the agent/ folder on agent-control changed, update this code and restart.
sync_control() {
  git -C "$REPO" fetch -q origin agent-control 2>/dev/null || return 0
  local ref=refs/remotes/origin/agent-control tree
  git -C "$REPO" show "$ref:control.json" > "$STATE/control.json.new" 2>/dev/null && mv "$STATE/control.json.new" "$STATE/control.json"
  tree=$(git -C "$REPO" rev-parse "$ref:agent" 2>/dev/null) || return 0
  [ "$tree" = "$(cat "$STATE/agent-tree" 2>/dev/null)" ] && return 0
  if git -C "$REPO" archive "$ref" agent | tar x --strip-components=1 -C "$AGENT_DIR"; then
    echo "$tree" > "$STATE/agent-tree"
    chmod +x "$AGENT_DIR"/*.sh "$AGENT_DIR/anyps5"
    log "agent code updated from agent-control (${tree:0:10}); restarting"
    exec "$AGENT_DIR/agent.sh"
  fi
}

# Publish status.json, report.md and README.md to the agent-status branch (one commit, force-pushed).
publish_status() {
  local d="$STATE/status-out"
  rm -rf "$d"; mkdir -p "$d"
  python3 "$AGENT_DIR/status.py" --state "$STATE" --out "$d" --upstream "$UPSTREAM" --owner "$FORK_OWNER" --cap "$(cap)" 2>>"$LOG" || return 0
  (cd "$d" && git init -q && git add -A \
    && git -c user.name="$FORK_OWNER" -c user.email="$(git -C "$REPO" config user.email)" commit -q -m "status $(date -u +%FT%TZ)" \
    && git push -q -f "$(git -C "$REPO" remote get-url origin)" HEAD:agent-status) 2>>"$LOG" || log "  status publish failed"
}

render() {
  python3 - "$@" <<'EOF'
import sys
text = open(sys.argv[1]).read()
for pair in sys.argv[2:]:
    key, value = pair.split("=", 1)
    if value.startswith("@"):
        value = open(value[1:]).read()
    text = text.replace("{{" + key + "}}", value)
print(text)
EOF
}

# claude_run <model> <max-turns> <prompt-file> <log-name>
claude_run() {
  local model=$1 turns=$2 prompt=$3 name=$4 out rc
  out="$STATE/runs/$(date +%Y%m%d-%H%M%S)-$name.json"
  for _ in 1 2 3 4 5 6 7 8; do
    (cd "$REPO" && GH_TOKEN=agent-has-no-github GITHUB_TOKEN=agent-has-no-github timeout 3h \
      claude -p --model "$model" --max-turns "$turns" --output-format json \
        --dangerously-skip-permissions --disallowedTools "Bash(git push:*)" "Bash(gh:*)" \
        < "$prompt") > "$out" 2>&1
    rc=$?
    if python3 - "$out" <<'EOF'
import json, re, sys
raw = open(sys.argv[1]).read()
try:
    data = json.loads(raw)
    hit = data.get("is_error") and re.search(r"limit|overloaded|529|resets", str(data.get("result", "")), re.I)
except ValueError:
    hit = re.search(r"usage limit|rate limit|overloaded|resets at", raw, re.I)
sys.exit(0 if hit else 1)
EOF
    then
      log "  $model hit a usage limit; waiting 30 min"
      sleep 1800
      continue
    fi
    [ $rc -eq 0 ] || log "  $model exited with $rc (log: $out)"
    return $rc
  done
  return 1
}

sync_upstream() {
  git -C "$REPO" fetch -q upstream main && git -C "$REPO" fetch -q --prune origin
}

checkout_fresh() {
  git -C "$REPO" reset -q --hard
  git -C "$REPO" clean -qfd
  git -C "$REPO" checkout -q -B "$1" "$2"
  git -C "$REPO" submodule update -q --init --recursive
}

# build_and_test <task-dir> <title> <body-file>: writes <task-dir>/failure.md and returns 1 on failure
build_and_test() {
  local t=$1 title=$2 body=$3 failed new
  cd "$REPO"
  if ! cmake --build build --parallel "$JOBS" > "$t/build.log" 2>&1; then
    { echo "## Build failed"; echo '```'; grep -E "error|Error" "$t/build.log" | head -40; tail -20 "$t/build.log"; echo '```'; } > "$t/failure.md"
    return 1
  fi
  ctest --test-dir build -j "$JOBS" --timeout 120 --output-on-failure > "$t/ctest.log" 2>&1
  failed=$(sed -n '/The following tests FAILED/,$p' "$t/ctest.log" | grep -oE '^\s+[0-9]+ - \S+' | awk '{print $3}' | sort -u)
  new=$(comm -23 <(echo "$failed" | grep -v '^$') <(sort -u "$STATE/baseline-failures.txt" 2>/dev/null))
  if [ -n "$new" ]; then
    { echo "## Tests that fail on this branch but pass on main"; echo "$new"; echo '```'; grep -B2 -A30 -F "$(echo "$new" | head -1)" "$t/ctest.log" | head -80; echo '```'; } > "$t/failure.md"
    return 1
  fi
  if ! python3 tools/check_conventions.py --base upstream/main --title "$title" --body "$body" > "$t/conventions.log" 2>&1; then
    { echo "## tools/check_conventions.py failed"; echo '```'; tail -40 "$t/conventions.log"; echo '```'; } > "$t/failure.md"
    return 1
  fi
  return 0
}

refresh_baseline() {
  local stamp="$STATE/baseline-failures.txt"
  [ -f "$stamp" ] && [ "$(find "$stamp" -mmin -1440)" ] && return 0
  log "refreshing test baseline on upstream/main"
  checkout_fresh agent-baseline upstream/main
  cd "$REPO"
  cmake --build build --parallel "$JOBS" > "$STATE/baseline-build.log" 2>&1 || { log "  main does not build here; see baseline-build.log"; return 1; }
  ctest --test-dir build -j "$JOBS" --timeout 120 > "$STATE/baseline-ctest.log" 2>&1
  sed -n '/The following tests FAILED/,$p' "$STATE/baseline-ctest.log" | grep -oE '^\s+[0-9]+ - \S+' | awk '{print $3}' | sort -u > "$stamp"
  log "  baseline: $(wc -l < "$stamp") tests already fail on main on this machine"
}

commit_work() {
  local t=$1
  cd "$REPO"
  git add -A -- . ':(exclude)3rdparty'
  if git log -1 --format=%H upstream/main..HEAD | grep -q .; then
    git commit -q --amend -F "$t/commit.txt"
  else
    git diff --cached --quiet && return 1
    git commit -q -F "$t/commit.txt"
  fi
}

# ---------- follow-up on this contributor's open upstream PRs ----------
follow_up_prs() {
  local prs n branch t hash
  prs=$(gh pr list --repo "$UPSTREAM" --author "$FORK_OWNER" --state open --json number,headRefName --jq '.[] | "\(.number) \(.headRefName)"') || return 0
  echo "$(echo "$prs" | grep -c .)" > "$STATE/open-pr-count"
  while read -r n branch; do
    [ -n "$n" ] || continue
    t="$STATE/followup/$n"; mkdir -p "$t"
    {
      echo "# PR #$n ($branch)"
      gh pr view "$n" --repo "$UPSTREAM" --json mergeable,reviewDecision --jq '"Mergeable: \(.mergeable)  Review decision: \(.reviewDecision)"'
      echo "## Reviews"
      gh pr view "$n" --repo "$UPSTREAM" --json reviews --jq '.reviews[] | select(.author.login != "'"$FORK_OWNER"'") | "- \(.author.login) [\(.state)]: \(.body)"'
      echo "## Inline review comments"
      gh api "repos/$UPSTREAM/pulls/$n/comments" --paginate --jq '.[] | select(.user.login != "'"$FORK_OWNER"'") | "- \(.user.login) on \(.path):\(.line // .original_line): \(.body)"'
      echo "## Conversation"
      gh pr view "$n" --repo "$UPSTREAM" --json comments --jq '.comments[] | select(.author.login != "'"$FORK_OWNER"'" and (.author.login | test("bot|github-actions") | not)) | "- \(.author.login): \(.body)"'
      echo "## Failing checks"
      gh pr view "$n" --repo "$UPSTREAM" --json statusCheckRollup --jq '.statusCheckRollup[] | select(.conclusion == "FAILURE") | "- \(.name // .context): \(.detailsUrl // .targetUrl)"'
    } > "$t/feedback.md" 2>/dev/null
    hash=$(sha256sum "$t/feedback.md" | cut -c1-16)
    if [ "$hash" = "$(cat "$t/seen" 2>/dev/null)" ] && ! ctl followup_prs "" | grep -qw "$n"; then continue; fi
    if ! grep -qE 'CONFLICTING|CHANGES_REQUESTED|^- ' "$t/feedback.md"; then
      echo "$hash" > "$t/seen"; continue
    fi
    log "PR #$n has new feedback; following up"
    sync_upstream
    checkout_fresh "$branch" "origin/$branch"
    rm -f "$t/reply.md" "$t/nothing.txt" "$t/failure.md"
    render "$AGENT_DIR/prompts/followup.md" "FEEDBACK=@$t/feedback.md" "OUT=$t" "JOBS=$JOBS" > "$t/prompt.md"
    claude_run sonnet 150 "$t/prompt.md" "followup-$n"
    echo "$hash" > "$t/seen"
    [ -f "$t/nothing.txt" ] && { log "  nothing to change"; continue; }
    gh pr view "$n" --repo "$UPSTREAM" --json body --jq .body > "$t/body.md"
    title=$(gh pr view "$n" --repo "$UPSTREAM" --json title --jq .title)
    if build_and_test "$t" "$title" "$t/body.md"; then
      git -C "$REPO" push -q --force-with-lease origin "$branch" && log "  pushed follow-up to PR #$n"
      report "" "## $(date '+%F %H:%M') — PR #$n updated" \
        "Post the reply below on https://github.com/$UPSTREAM/pull/$n and re-request review (pushing alone does not answer a change request)." \
        "Reply draft: \`$t/reply.md\`"
    else
      log "  follow-up for PR #$n failed checks; left unpushed ($t/failure.md)"
      report "" "## $(date '+%F %H:%M') — PR #$n needs you" "The agent's follow-up did not pass checks. See \`$t/failure.md\` and \`$t/feedback.md\`."
    fi
  done <<< "$prs"
}

# ---------- one new contribution ----------
new_contribution() {
  local id t branch lib title verdict attempt
  id=$(date +%Y%m%d-%H%M%S); t="$STATE/tasks/$id"; mkdir -p "$t"
  sync_upstream
  checkout_fresh agent-scout upstream/main

  log "scouting"
  python3 "$AGENT_DIR/candidates.py" --repo "$REPO" --state "$STATE" --out "$t/candidates.json" >> "$LOG" 2>&1 || { log "  candidates.py failed"; return 1; }
  render "$AGENT_DIR/prompts/scout.md" "CANDIDATES=$t/candidates.json" "SKIPPED=$STATE/skip.txt" "OUT=$t/task.json" > "$t/prompt-scout.md"
  claude_run haiku 40 "$t/prompt-scout.md" "scout-$id"
  [ -s "$t/task.json" ] || { log "  scout wrote no task"; return 1; }
  lib=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("library") or "")' "$t/task.json")
  if [ -z "$lib" ]; then
    python3 -c 'import json,sys; [print(f, "scout") for f in json.load(open(sys.argv[1])).get("skip", [])]' "$t/task.json" >> "$STATE/skip.txt"
    log "  scout found nothing feasible in this batch"; return 1
  fi
  funcs=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["functions"]))' "$t/task.json")
  branch="agent/${lib#libSce}-$(echo "${funcs%% *}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | cut -c1-40)"
  log "  task: $lib: $funcs -> $branch"

  checkout_fresh "$branch" upstream/main
  render "$AGENT_DIR/prompts/implement.md" "TASK=@$t/task.json" "LIBRARY=$lib" "OUT=$t" "JOBS=$JOBS" > "$t/prompt-implement.md"
  log "implementing (sonnet)"
  claude_run sonnet 200 "$t/prompt-implement.md" "implement-$id"

  for attempt in 1 2 3 4; do
    if [ -f "$t/skip.txt" ]; then
      for f in $funcs; do echo "$f $(head -1 "$t/skip.txt")" >> "$STATE/skip.txt"; done
      log "  skipped: $(head -1 "$t/skip.txt")"; return 1
    fi
    [ -s "$t/commit.txt" ] && [ -s "$t/pr.md" ] || { log "  implementer left no commit.txt/pr.md"; echo "$funcs no-output" >> "$STATE/skip.txt"; return 1; }
    commit_work "$t" || { log "  no changes made"; echo "$funcs no-change" >> "$STATE/skip.txt"; return 1; }
    title=$(head -1 "$t/commit.txt")

    log "checking (attempt $attempt)"
    if ! build_and_test "$t" "$title" "$t/pr.md"; then
      [ $attempt -ge 3 ] && break
      render "$AGENT_DIR/prompts/fix.md" "TASK=@$t/task.json" "FAILURE=@$t/failure.md" "OUT=$t" > "$t/prompt-fix.md"
      claude_run sonnet 120 "$t/prompt-fix.md" "fix-$id-$attempt"
      continue
    fi

    log "reviewing (opus)"
    rm -f "$t/review.json"
    render "$AGENT_DIR/prompts/review.md" "TASK=@$t/task.json" "PR_BODY=@$t/pr.md" "OUT=$t" > "$t/prompt-review.md"
    claude_run opus 60 "$t/prompt-review.md" "review-$id-$attempt"
    git -C "$REPO" reset -q --hard HEAD
    verdict=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$t/review.json" 2>/dev/null || echo missing)
    log "  review: $verdict"
    case $verdict in
      approve)
        git -C "$REPO" push -q -u --force-with-lease origin "$branch" || { log "  push failed"; return 1; }
        mkdir -p "$STATE/ready/${branch//\//_}"; cp "$t/pr.md" "$t/commit.txt" "$t/task.json" "$STATE/ready/${branch//\//_}/"
        for f in $funcs; do echo "$f $branch" >> "$STATE/done.txt"; done
        bump_today
        local pr_file="$STATE/ready/${branch//\//_}/pr.md"
        report "" "## $(date '+%F %H:%M') — ready: $title" \
          "Branch \`$branch\` on your fork. Issues: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("issues") or "none")' "$t/task.json")" \
          "Review: https://github.com/$FORK_OWNER/AnyPS5/compare/main...$branch" \
          "Open it: \`gh pr create --repo $UPSTREAM --head $FORK_OWNER:$branch --title \"$title\" --body-file $pr_file\`"
        log "  pushed $branch ($(count_today)/$(cap) today)"
        return 0 ;;
      changes)
        [ $attempt -ge 3 ] && break
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("## Reviewer requested changes\n" + "\n".join("- " + p for p in d["problems"]))' "$t/review.json" > "$t/failure.md"
        render "$AGENT_DIR/prompts/fix.md" "TASK=@$t/task.json" "FAILURE=@$t/failure.md" "OUT=$t" > "$t/prompt-fix.md"
        claude_run sonnet 120 "$t/prompt-fix.md" "fix-$id-review-$attempt" ;;
      *)
        for f in $funcs; do echo "$f review-$verdict" >> "$STATE/skip.txt"; done
        log "  dropped after review ($verdict)"; return 1 ;;
    esac
  done
  for f in $funcs; do echo "$f gave-up" >> "$STATE/skip.txt"; done
  log "  gave up on $branch; work kept in local branch"
  return 1
}

# ---------- main loop ----------
log "agent started (cap $(cap)/day, $JOBS build jobs)"
while true; do
  sync_control
  if paused; then publish_status; sleep 600; continue; fi
  follow_up_prs
  sync_upstream && refresh_baseline
  if [ "$(count_today)" -ge "$(cap)" ]; then
    publish_status; sleep 3600; continue
  fi
  new_contribution
  publish_status
  sleep 600
done
