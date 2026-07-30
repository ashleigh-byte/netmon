#!/usr/bin/env bash
#
# setup-netmon.sh
#
# One-shot setup for netmon on Linux, using the ashleigh-byte fork's
# main branch (the personal "ground truth" branch with every feature
# merged in -- not yet reviewed/merged upstream). Prompts you to choose between
# the Ookla speedtest CLI backend and classic speedtest-cli -- see the
# in-script prompt for the tradeoffs (Ookla saturates your line on every
# test cycle to measure true capacity and reports jitter/packet loss;
# speedtest-cli is single-connection and lighter, but under-reports on
# fast connections and has no jitter data).
#
# The system-package steps (nmap/git/curl, and speedtest-cli if chosen)
# support Debian/Ubuntu (apt), Fedora/RHEL/Rocky/Alma (dnf, falling back
# to yum), Arch/Manjaro (pacman), openSUSE (zypper), and Alpine (apk) --
# everything else in this script (uv, git clone, the Ookla installer,
# .env setup) is already distro-agnostic. Only the apt path has actually
# been exercised end-to-end; the others follow each distro's own
# idiomatic install command for the same package names, but test on
# your specific distro before relying on it unattended.
#
# Run as the normal user who will own the service (not root) -- it
# calls sudo itself for the steps that need it.
#
# Usage: bash setup-netmon.sh
#        INSTALL_DIR=/opt/netmon bash setup-netmon.sh   # custom install path

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Please run this as your normal user, not root/sudo -- it calls sudo itself" >&2
    echo "only for the steps that need it (nmap sudoers grant, package installs," >&2
    echo "speed test backend installer)." >&2
    exit 1
fi

REPO_URL="https://github.com/ashleigh-byte/netmon.git"
# Intentionally "main", not whatever branch you're reading this on: main is
# the personal "ground truth" branch with every feature merged in, and is
# what this script is meant to deploy. If you want to stand up a specific
# feature/testing branch instead, just edit this line yourself.
BRANCH="main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# install_pkgs pkg1 [pkg2 ...]
# Installs the given package(s) using whichever supported package manager
# is on PATH (apt/dnf/yum/pacman/zypper/apk), using each distro's own
# idiomatic install command -- these three-to-four package names (nmap,
# git, curl, speedtest-cli) are named identically across all of them, so
# no per-distro name mapping is needed. Only the apt path has actually
# been exercised end-to-end; exits with a clear manual-install pointer if
# none of the six are found, rather than failing unhelpfully.
install_pkgs() {
    if command -v apt >/dev/null 2>&1; then
        sudo apt install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y "$@"
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm "$@"
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper --non-interactive install "$@"
    elif command -v apk >/dev/null 2>&1; then
        sudo apk add "$@"
    else
        echo "Could not detect a supported package manager (apt/dnf/yum/pacman/zypper/apk)." >&2
        echo "Install $* yourself, then re-run this script -- it will pick up from" >&2
        echo "the next step once those are on PATH." >&2
        exit 1
    fi
}

# prompt_var NAME "Prompt text" ["default"]
# Reads a line of input into the variable named NAME. If a default is
# given, it's shown in [brackets] and used when the user just hits Enter.
prompt_var() {
    local __name="$1" __prompt="$2" __default="${3:-}" __input
    if [ -n "${__default}" ]; then
        read -rp "${__prompt} [${__default}]: " __input
        __input="${__input:-${__default}}"
    else
        read -rp "${__prompt}: " __input
    fi
    printf -v "${__name}" '%s' "${__input}"
}

if command -v apt >/dev/null 2>&1; then
    sudo apt update
fi

echo "==> Installing system dependencies (nmap, git, curl)"
install_pkgs nmap git curl

echo "==> Allowing passwordless sudo for nmap (needed for ARP-based device scanning)"
echo "$(whoami) ALL=(root) NOPASSWD: $(command -v nmap)" | sudo tee /etc/sudoers.d/netmon-nmap > /dev/null
sudo chmod 440 /etc/sudoers.d/netmon-nmap

if ! command -v uv >/dev/null 2>&1; then
    echo "==> Installing uv"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

# This script ships inside the repo itself (checked out alongside main.py,
# pyproject.toml, etc.) -- if it's being run from there, there's no need to
# clone a second copy. Only fall back to cloning when it's been downloaded
# standalone (e.g. via curl) onto a machine with no checkout yet.
if [ -f "${SCRIPT_DIR}/pyproject.toml" ] && grep -q '^name = "netmon"' "${SCRIPT_DIR}/pyproject.toml" 2>/dev/null; then
    echo "==> Running from an existing netmon checkout at ${SCRIPT_DIR} -- skipping clone"
    INSTALL_DIR="${SCRIPT_DIR}"
else
    INSTALL_DIR="${INSTALL_DIR:-$HOME/netmon}"
    echo "==> Fetching netmon (${BRANCH} branch) into ${INSTALL_DIR}"
    if [ -d "${INSTALL_DIR}/.git" ]; then
        echo "    ${INSTALL_DIR} already exists -- pulling latest instead of cloning"
        git -C "${INSTALL_DIR}" fetch origin
        git -C "${INSTALL_DIR}" checkout "${BRANCH}"
        git -C "${INSTALL_DIR}" pull
    else
        git clone "${REPO_URL}" "${INSTALL_DIR}"
        git -C "${INSTALL_DIR}" checkout "${BRANCH}"
    fi
fi

cd "${INSTALL_DIR}"

echo "==> Installing Python dependencies via uv"
uv sync

echo
echo "==> Speed test backend"
echo
echo "  1) Ookla CLI (default, recommended on fast connections)"
echo "     + Multi-threaded -- measures your line's true capacity accurately;"
echo "       classic speedtest-cli under-reports on connections above roughly"
echo "       500 Mbps, where its own single-threaded CPU overhead becomes the"
echo "       bottleneck rather than your actual line."
echo "     + Also reports jitter and packet loss, unlocking bufferbloat"
echo "       reporting in netmon's AI commentary."
echo "     - Uses noticeably more bandwidth per test: it opens several"
echo "       parallel connections and will actively try to saturate your"
echo "       line to measure its ceiling. This happens on every cycle"
echo "       (every SLEEP_TIME, default 30 min), not just once -- if that"
echo "       cycle lands while someone's mid video call or game, they may"
echo "       notice it."
echo
echo "  2) speedtest-cli (classic, lighter)"
echo "     + Single connection only -- approximates what one real application"
echo "       actually gets, and uses far less bandwidth per test since it"
echo "       never tries to max out the line."
echo "     - Under-reports real throughput on very fast connections"
echo "       (roughly 500 Mbps+)."
echo "     - No jitter/packet-loss data -- bufferbloat reporting stays"
echo "       inactive with this backend."
echo
prompt_var SPEEDTEST_BACKEND "Choose 1 or 2" "1"

if [ "${SPEEDTEST_BACKEND}" = "2" ]; then
    echo "==> Installing classic speedtest-cli"
    install_pkgs speedtest-cli
else
    echo "==> Installing Ookla's speedtest CLI (static binary, not speedtest-cli)"
    sudo bash install-ookla-speedtest.sh
fi

# ---------------------------------------------------------------------------
# .env configuration
# ---------------------------------------------------------------------------

cp -n .env.example .env   # -n: never clobber an existing .env from a prior run

# set_env_var KEY VALUE
# Uncomments and/or updates KEY=... in .env, or appends it if it's not
# present at all yet. Matches both "KEY=..." and "# KEY=..." (with any
# amount of leading whitespace) so it works against .env.example's
# commented-out optional defaults as well as already-set values.
set_env_var() {
    local key="$1" value="$2"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" .env; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${key}=${value}|" .env
    else
        printf '%s=%s\n' "${key}" "${value}" >> .env
    fi
}

echo
echo "==> Configuring .env -- required settings"
echo

prompt_var AI_API_KEY      "AI API key (any string works for most local servers, e.g. Ollama)"
prompt_var AI_MODEL        "AI model name" "gpt-4o-mini"
prompt_var AI_BASE_URL     "AI base URL" "https://api.openai.com/v1"
prompt_var DB_PATH         "Database file path" "metrics.sql"
prompt_var NOTIFIER        "Notifier (telegram/discord)" "telegram"

set_env_var AI_API_KEY "${AI_API_KEY}"
set_env_var AI_MODEL "${AI_MODEL}"
set_env_var AI_BASE_URL "${AI_BASE_URL}"
set_env_var DB_PATH "${DB_PATH}"
set_env_var NOTIFIER "${NOTIFIER}"

if [ "${NOTIFIER}" = "discord" ]; then
    prompt_var DISCORD_WEBHOOK_URL "Discord webhook URL"
    set_env_var DISCORD_WEBHOOK_URL "${DISCORD_WEBHOOK_URL}"
else
    prompt_var TG_BOT_TOKEN "Telegram bot token (from @BotFather)"
    prompt_var TG_CHAT_ID   "Telegram chat ID"
    set_env_var TG_BOT_TOKEN "${TG_BOT_TOKEN}"
    set_env_var TG_CHAT_ID "${TG_CHAT_ID}"
fi

echo
read -rp "Configure optional settings now (timing, outage/heartbeat/retention thresholds)? [y/N]: " configure_optional
echo

if [[ "${configure_optional}" =~ ^[Yy]$ ]]; then
    prompt_var SLEEP_TIME                          "Seconds between each speed test + device scan cycle" "1800"
    prompt_var REPORT_CYCLE_COUNT                  "Cycles between detailed AI reports with graph" "8"
    prompt_var RETENTION_DAYS                      "Days of history to keep before pruning" "90"
    prompt_var OUTAGE_DOWNLOAD_THRESHOLD_MBPS      "Outage-alert download threshold (Mbps)" "20"
    prompt_var OUTAGE_PING_THRESHOLD_MS            "Outage-alert ping threshold (ms)" "150"
    prompt_var OUTAGE_CONSECUTIVE_READINGS         "Consecutive bad readings before an outage alert" "2"
    prompt_var DEVICE_MISSING_LOOKBACK_DAYS        "Missing-device reliability lookback window (days)" "3"
    prompt_var DEVICE_MISSING_RELIABILITY          "Missing-device reliability threshold (0-1)" "0.8"
    prompt_var DEVICE_MISSING_CONSECUTIVE_READINGS "Consecutive missing checks before an alert" "2"
    prompt_var HEARTBEAT_HOST                      "Connectivity heartbeat target host" "1.1.1.1"
    prompt_var HEARTBEAT_PORT                      "Connectivity heartbeat target port" "443"
    prompt_var HEARTBEAT_INTERVAL_SECONDS          "Heartbeat check interval (seconds)" "60"
    prompt_var HEARTBEAT_CONSECUTIVE_FAILURES      "Consecutive heartbeat failures before an alert" "3"

    for key in SLEEP_TIME REPORT_CYCLE_COUNT RETENTION_DAYS \
        OUTAGE_DOWNLOAD_THRESHOLD_MBPS OUTAGE_PING_THRESHOLD_MS OUTAGE_CONSECUTIVE_READINGS \
        DEVICE_MISSING_LOOKBACK_DAYS DEVICE_MISSING_RELIABILITY DEVICE_MISSING_CONSECUTIVE_READINGS \
        HEARTBEAT_HOST HEARTBEAT_PORT HEARTBEAT_INTERVAL_SECONDS HEARTBEAT_CONSECUTIVE_FAILURES; do
        set_env_var "${key}" "${!key}"
    done
else
    echo "Skipping -- the defaults documented in .env.example will be used."
fi

echo
echo "==> Setup complete."
echo
echo "Test it (forces one full detailed-report cycle immediately):"
echo "    cd ${INSTALL_DIR} && uv run main.py --test-ai"
echo
echo "Once you're happy, set it up as a systemd service to run 24/7 --"
echo "see the README's 'Run the Bot' section for a sample unit file."
