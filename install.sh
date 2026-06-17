#!/bin/sh

# Script to install urltest_proxy_links_updater.sh into OpenWrt crontab
# Default: every 15 minutes (*/15 * * * *)

UPDATER_SCRIPT_DOWNLOAD_URL="https://raw.githubusercontent.com/msgtv/podkop_urltest_proxy_links_updater/refs/heads/main/urltest_proxy_links_updater.sh"

# Installation directories
UPDATER_DIR="/opt/podkop_urltest_proxy_links_updater"        # Main installation directory for scripts
UPDATER_CONF_DIR="/etc/podkop_urltest_proxy_links_updater"   # Configuration directory for sub_link

# Where cron job output will be appended (OpenWrt has no MTA by default,
# so stdout/stderr of the cron job must go somewhere or it gets lost).
UPDATER_LOG="/var/log/podkop_urltest_updater.log"

# Full paths to installed files
UPDATER_SCRIPT="$UPDATER_DIR/urltest_proxy_links_updater.sh"  # Main updater script path
UPDATER_SUB_LINK="$UPDATER_CONF_DIR/sub_link"                 # Copied subscription file path

# -----------------------------------------------------------------------------
# Show help message
# -----------------------------------------------------------------------------
show_help() {
    cat <<EOF
Install urltest_proxy_links_updater.sh into OpenWrt crontab.

The updater script is downloaded from GitHub into:
  $UPDATER_DIR/
The subscription file you provide is copied to:
  $UPDATER_CONF_DIR/sub_link

Usage:
  $0 <sub_link_path> [minutes] [hours] [days] [months] [weekdays]
  $0 -h | --help

Arguments:
  sub_link_path  Path to subscription file (REQUIRED).
                 The file will be copied to $UPDATER_SUB_LINK
                 and the cron job will use that stable path.
  minutes        0-59, */N or *  (default: */15)
  hours          0-23 or *        (default: *)
  days           1-31 or *        (default: *)
  months         1-12 or *        (default: *)
  weekdays       0-7 (0 and 7 = Sunday) or * (default: *)

Examples:
  $0 /etc/podkop/my_sub.txt             # every 15 minutes (default)
  $0 /root/sub_link 0 */6 * * *         # every 6 hours
  $0 /root/sub_link 0 3 * * *           # every day at 3:00
  $0 /root/sub_link 0 0 * * 0           # every Sunday at 00:00
  $0 /root/sub_link 30 */4 * * *        # every 4 hours at :30
  $0 /root/sub_link 0 2,14 * * *        # at 2:00 and 14:00 every day
EOF
    exit 0
}

# -----------------------------------------------------------------------------
# Validate a single cron field. Allows: *, */N, N, N-M, N,M,...
# Returns: 0 if valid, 1 otherwise
# -----------------------------------------------------------------------------
validate_cron_field() {
    local field="$1"
    local name="$2"

    if [ -z "$field" ]; then
        echo "Error: $name is empty"
        return 1
    fi

    # Allowed characters: digits, *, /, ,, -
    if ! echo "$field" | grep -qE '^[0-9*/,-]+$'; then
        echo "Error: invalid $name '$field' (allowed: digits, *, /, ,, -)"
        return 1
    fi

    return 0
}

# =============================================================================
# Pre-flight checks (no filesystem writes yet)
# =============================================================================

# Handle -h/--help FIRST, before anything else (must work without root)
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
fi

# Must be root (we write to /opt, /etc, modify crontab, restart services)
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root"
    exit 1
fi

# Check if sub_link_path argument is provided
if [ -z "$1" ]; then
    echo "Error: sub_link_path argument is required"
    echo ""
    show_help
fi

# First argument is the path to subscription file provided by user
SUB_FILE="$1"
shift

# Check that the source subscription file exists BEFORE we try to copy it.
# (Old version of this script ran `cp` first and only warned afterwards,
# which led to a broken install if the file was missing.)
if [ ! -f "$SUB_FILE" ]; then
    echo "Error: subscription file '$SUB_FILE' not found"
    exit 1
fi
if [ ! -s "$SUB_FILE" ]; then
    echo "Error: subscription file '$SUB_FILE' is empty"
    exit 1
fi

# Get cron parameters from arguments or use defaults
# Cron format: minutes hours days months weekdays
CRON_MINUTES="${1:-*/15}"
CRON_HOURS="${2:-*}"
CRON_DAYS="${3:-*}"
CRON_MONTHS="${4:-*}"
CRON_WEEKDAYS="${5:-*}"

# Validate each cron field
validate_cron_field "$CRON_MINUTES"  "minutes"  || exit 1
validate_cron_field "$CRON_HOURS"    "hours"    || exit 1
validate_cron_field "$CRON_DAYS"     "days"     || exit 1
validate_cron_field "$CRON_MONTHS"   "months"   || exit 1
validate_cron_field "$CRON_WEEKDAYS" "weekdays" || exit 1

# Build cron schedule string
CRON_SCHEDULE="$CRON_MINUTES $CRON_HOURS $CRON_DAYS $CRON_MONTHS $CRON_WEEKDAYS"

# =============================================================================
# All pre-flight checks passed — proceed with installation
# =============================================================================

echo "========================================"
echo "Installing urltest_proxy_links_updater to crontab"
echo "========================================"
echo ""
echo "Subscription file: $SUB_FILE"
echo "Execution schedule: $CRON_SCHEDULE"
echo "  Minutes:   $CRON_MINUTES"
echo "  Hours:     $CRON_HOURS"
echo "  Days:      $CRON_DAYS"
echo "  Months:    $CRON_MONTHS"
echo "  Weekdays:  $CRON_WEEKDAYS"
echo ""

# Create installation directories
mkdir -p "$UPDATER_DIR" || {
    echo "Error: failed to create $UPDATER_DIR"
    exit 1
}
mkdir -p "$UPDATER_CONF_DIR" || {
    echo "Error: failed to create $UPDATER_CONF_DIR"
    exit 1
}

# -----------------------------------------------------------------------------
# Optional pre-flight: warn if podkop is not in urltest mode.
# The updater script's check_prerequisites() will exit early in that case,
# but warning here gives the user a chance to fix it before install.
# -----------------------------------------------------------------------------
PROXY_CONFIG_TYPE=$(uci get podkop.@section[0].proxy_config_type 2>/dev/null)
if [ -n "$PROXY_CONFIG_TYPE" ] && [ "$PROXY_CONFIG_TYPE" != "urltest" ]; then
    echo "WARNING: podkop proxy_config_type is '$PROXY_CONFIG_TYPE' (expected 'urltest')."
    echo "         The updater will fail at check_prerequisites until podkop is switched"
    echo "         to urltest mode. Continuing install anyway..."
    echo ""
elif [ -z "$PROXY_CONFIG_TYPE" ]; then
    echo "WARNING: could not read podkop proxy_config_type via uci."
    echo "         Either podkop is not installed, or its config is missing."
    echo "         Continuing install anyway..."
    echo ""
fi

# -----------------------------------------------------------------------------
# Copy the user-provided subscription file to a stable system path.
# -L: dereference symlinks (in case the user gave us a symlink to /tmp/...)
# -f: overwrite an existing read-only copy from a previous install
# -----------------------------------------------------------------------------
cp -fL "$SUB_FILE" "$UPDATER_SUB_LINK" || {
    echo "Error: failed to copy '$SUB_FILE' to '$UPDATER_SUB_LINK'"
    exit 1
}
if [ ! -s "$UPDATER_SUB_LINK" ]; then
    echo "Error: subscription file is empty after copy ('$UPDATER_SUB_LINK')"
    exit 1
fi
echo "Subscription file copied to: $UPDATER_SUB_LINK"
echo ""

# -----------------------------------------------------------------------------
# Download the updater script from GitHub.
# This ensures we always have the latest version.
# -----------------------------------------------------------------------------
echo "Downloading updater script from GitHub..."
if ! wget -q -O "$UPDATER_SCRIPT" "$UPDATER_SCRIPT_DOWNLOAD_URL"; then
    rm -f "$UPDATER_SCRIPT"
    echo "Error: Failed to download updater script from $UPDATER_SCRIPT_DOWNLOAD_URL"
    echo "Please check your internet connection and try again"
    exit 1
fi

# Verify the downloaded file is not empty (catches 404 pages, etc.)
if [ ! -s "$UPDATER_SCRIPT" ]; then
    rm -f "$UPDATER_SCRIPT"
    echo "Error: Downloaded script is empty"
    exit 1
fi

# Sanity check: first line should be a shebang
if ! head -1 "$UPDATER_SCRIPT" | grep -qE '^#!'; then
    rm -f "$UPDATER_SCRIPT"
    echo "Error: downloaded file does not look like a shell script (no shebang on first line)"
    echo "       URL may have returned an HTML error page"
    exit 1
fi

# Make the script executable
chmod +x "$UPDATER_SCRIPT"
echo "Updater script downloaded successfully: $UPDATER_SCRIPT"
echo ""

# -----------------------------------------------------------------------------
# Build cron job.
# Redirect stdout+stderr to a log file because OpenWrt has no MTA by default,
# so cron output would otherwise be silently discarded.
# -----------------------------------------------------------------------------
CRON_JOB="$CRON_SCHEDULE $UPDATER_SCRIPT $UPDATER_SUB_LINK >> $UPDATER_LOG 2>&1"

echo "Adding task to crontab..."
echo "Task: $CRON_JOB"
echo ""

# Remove old task(s) if exists (to avoid duplicates).
# Match on the full script path so we don't accidentally remove unrelated jobs.
(crontab -l 2>/dev/null | grep -vF "$UPDATER_SCRIPT") | crontab -

# Add new task
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

if [ $? -ne 0 ]; then
    echo "Error: failed to add task to crontab"
    exit 1
fi

echo "Task successfully added to crontab"
echo ""
echo "Current cron tasks:"
echo "----------------------------------------"
crontab -l 2>/dev/null | grep -F "$UPDATER_SCRIPT"
echo "----------------------------------------"
echo ""

# -----------------------------------------------------------------------------
# Make sure the cron daemon is enabled and running on OpenWrt.
# Without this, the job we just added will never fire.
# -----------------------------------------------------------------------------
if [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron enable 2>/dev/null
    /etc/init.d/cron restart 2>/dev/null || /etc/init.d/cron start 2>/dev/null
    echo "cron service enabled and (re)started"
else
    echo "WARNING: /etc/init.d/cron not found — cron jobs may not run."
    echo "         Install the cron package: opkg update && opkg install cron"
fi
echo ""

echo "Installation completed successfully!"
echo ""
echo "Cron job output will be appended to: $UPDATER_LOG"
echo ""

# -----------------------------------------------------------------------------
# Run the updater once immediately.
# Use `|| { ... }` so that an initial failure (e.g. sing-box is healthy and the
# updater exits 0 early, or the subscription server is temporarily down) does
# not cause the install script to silently swallow the error — the cron job is
# already installed and will retry on schedule.
# -----------------------------------------------------------------------------
echo "Running initial update..."
echo "----------------------------------------"
"$UPDATER_SCRIPT" "$UPDATER_SUB_LINK" || {
    rc=$?
    echo "----------------------------------------"
    echo "WARNING: initial update exited with code $rc."
    echo "         The cron job is installed and will retry on schedule."
    echo "         Check the log at $UPDATER_LOG after the next run."
    exit "$rc"
}
echo "----------------------------------------"
echo ""

exit 0
