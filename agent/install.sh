#!/usr/bin/env bash
# One-time setup on the VPS. Safe to re-run.
set -euo pipefail
AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${REPO:-$HOME/src/AnyPS5}"
DAILY_CAP="${DAILY_CAP:-6}"
step() { printf '\n==> %s\n' "$*"; }

step "Checking logins"
command -v claude >/dev/null || { echo "claude CLI not found on PATH"; exit 1; }
gh api user --jq .login >/dev/null 2>&1 || { echo "gh is not logged in; run: gh auth login"; exit 1; }
OWNER=$(gh api user --jq .login)
OWNER_ID=$(gh api user --jq .id)
echo "GitHub: $OWNER   claude: $(command -v claude)"
claude -p --model haiku --max-turns 1 "Reply with OK" >/dev/null 2>&1 || { echo "claude -p failed; run 'claude' once and log in"; exit 1; }

step "Installing build dependencies (sudo)"
bash "$AGENT_DIR/deps.sh"

step "Setting up fork and remotes"
[ -d "$REPO/.git" ] || git clone -q https://github.com/boykopovar/AnyPS5 "$REPO"
cd "$REPO"
if git remote get-url origin 2>/dev/null | grep -q boykopovar; then git remote rename origin upstream; fi
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/boykopovar/AnyPS5.git
gh repo view "$OWNER/AnyPS5" >/dev/null 2>&1 || gh repo fork boykopovar/AnyPS5 --clone=false
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$OWNER/AnyPS5.git"
gh auth setup-git
git config user.name "$OWNER"
git config user.email "$OWNER_ID+$OWNER@users.noreply.github.com"
git fetch -q upstream main
git fetch -q origin
git checkout -q -B agent-baseline upstream/main
git submodule update --init --recursive

step "Configuring the full build (ccache)"
MEM_GB=$(awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo)
JOBS=$(( $(nproc) < MEM_GB / 2 ? $(nproc) : MEM_GB / 2 )); [ "$JOBS" -ge 1 ] || JOBS=1
ccache -M 20G >/dev/null
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON \
  -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache >/dev/null
echo "build jobs: $JOBS (cores $(nproc), RAM ${MEM_GB}G)"

step "Writing config"
cat > "$AGENT_DIR/config.sh" <<EOF
REPO="$REPO"
FORK_OWNER="$OWNER"
DAILY_CAP=$DAILY_CAP
JOBS=$JOBS
export PATH="$(dirname "$(command -v claude)"):$(dirname "$(command -v gh)"):/usr/local/bin:/usr/bin:/bin"
EOF
chmod +x "$AGENT_DIR"/*.sh "$AGENT_DIR/anyps5"
mkdir -p "$HOME/.local/bin" "$AGENT_DIR/state"
ln -sf "$AGENT_DIR/anyps5" "$HOME/.local/bin/anyps5"

step "Installing the systemd service (starts on boot, inside tmux session 'anyps5')"
sudo tee /etc/systemd/system/anyps5-agent.service >/dev/null <<EOF
[Unit]
Description=AnyPS5 contribution agent
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=$USER
Environment=HOME=$HOME
WorkingDirectory=$AGENT_DIR
ExecStart=/usr/bin/tmux new-session -d -s anyps5 "while true; do $AGENT_DIR/agent.sh; echo 'agent.sh exited; restarting in 60 s'; sleep 60; done"
ExecStop=/usr/bin/tmux kill-session -t anyps5
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now anyps5-agent.service

step "Done"
echo "The agent is running. The first round builds main and records which tests already fail on this machine."
echo "That first full build can take an hour or more; later builds are much faster thanks to ccache."
echo
echo "  anyps5 status    what it is doing, PRs ready for you"
echo "  anyps5 attach    watch it live (detach: Ctrl-b then d)"
echo "  anyps5 pause / resume / stop / start"
