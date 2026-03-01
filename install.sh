#!/bin/sh

# Script to install urltest_proxy_links_updater.sh into OpenWrt crontab
# Default: every 12 hours (0 */12 * * *)

UPDATER_SCRIPT_DOWNLOAD_URL="https://raw.githubusercontent.com/msgtv/podkop_urltest_proxy_links_updater/refs/heads/main/urltest_proxy_links_updater.sh"

# Installation directories
UPDATER_DIR="/opt/podkop_urltest_proxy_links_updater"        # Main installation directory for scripts
UPDATER_CONF_DIR="/etc/podkop_urltest_proxy_links_updater"   # Configuration directory for sub_link

# Create directories if they don't exist
mkdir -p "$UPDATER_DIR"
mkdir -p "$UPDATER_CONF_DIR"

# Full paths to installed files
UPDATER_SCRIPT="$UPDATER_DIR/urltest_proxy_links_updater.sh"  # Main updater script path
UPDATER_SUB_LINK="$UPDATER_CONF_DIR/sub_link"                 # Copied subscription file path

# Help display function
show_help() {
    echo "Install urltest_proxy_links_updater.sh into OpenWrt crontab"
    echo ""
    echo "Usage:"
    echo "  $0 [sub_link_path] [minutes] [hours] [days] [months] [weekdays]"
    echo "  $0 -h | --help"
    echo ""
    echo "Arguments:"
    echo "  sub_link_path  Path to subscription file (required)"
    echo "  minutes        0-59 or * (default: 0)"
    echo "  hours          0-23, */N or * (default: */12)"
    echo "  days           1-31 or * (default: *)"
    echo "  months         1-12 or * (default: *)"
    echo "  weekdays       0-7 (0 and 7 = Sunday) or * (default: *)"
    echo ""
    echo "Examples:"
    echo "  $0 /etc/podkop/my_sub.txt             # custom sub file, every 12 hours"
    echo "  $0 /root/sub_link 0 */6 * * *         # custom sub file, every 6 hours"
    echo "  $0 /root/sub_link 0 3 * * *           # every day at 3:00"
    echo "  $0 /root/sub_link 0 0 * * 0           # every Sunday at 00:00"
    echo "  $0 /root/sub_link 30 */4 * * *        # every 4 hours at :30"
    echo "  $0 /root/sub_link 0 2,14 * * *        # at 2:00 and 14:00 every day"
    echo ""
    echo "Description:"
    echo "  Copies urltest_proxy_links_updater.sh to /root/ and adds"
    echo "  a task to crontab for automatic subscription updates."
    exit 0
}

# Check arguments for help request
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
fi

# Check if sub_link_path argument is provided
if [ -z "$1" ]; then
    echo "Error: sub_link_path argument is required"
    echo ""
    show_help
fi

# First argument is the path to subscription file provided by user
SUB_FILE="$1"

# Copy user-provided subscription file to system config directory
# This ensures the cron job always uses a stable path
 cp "$SUB_FILE" "$UPDATER_SUB_LINK"
shift

# Get cron parameters from arguments or use defaults
# Cron format: minutes hours days months weekdays
CRON_MINUTES="${1:-0}"
CRON_HOURS="${2:-*/12}"
CRON_DAYS="${3:-*}"
CRON_MONTHS="${4:-*}"
CRON_WEEKDAYS="${5:-*}"

# Build cron schedule string
CRON_SCHEDULE="$CRON_MINUTES $CRON_HOURS $CRON_DAYS $CRON_MONTHS $CRON_WEEKDAYS"

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

# Download the updater script from GitHub
# This ensures we always have the latest version
if ! wget -q -O "$UPDATER_SCRIPT" "$UPDATER_SCRIPT_DOWNLOAD_URL"; then
    echo "Error: Failed to download updater script from $UPDATER_SCRIPT_DOWNLOAD_URL"
    echo "Please check your internet connection and try again"
    exit 1
fi

# Verify the downloaded file is not empty
if [ ! -s "$UPDATER_SCRIPT" ]; then
    echo "Error: Downloaded script is empty"
    exit 1
fi

# Make the script executable
chmod +x "$UPDATER_SCRIPT"
echo "Updater script downloaded successfully: $UPDATER_SCRIPT"
echo ""

# Check if subscription file exists
if [ ! -f "$SUB_FILE" ]; then
    echo "Warning: subscription file $SUB_FILE not found"
    echo "Create it before running the update script"
fi

# Build cron job
# Task will execute the script with the subscription file path
CRON_JOB="$CRON_SCHEDULE $UPDATER_SCRIPT $UPDATER_SUB_LINK"

echo "Adding task to crontab..."
echo "Task: $CRON_JOB"
echo ""

# Remove old task if exists (to avoid duplicates)
(crontab -l 2>/dev/null | grep -v "$UPDATER_SCRIPT") | crontab -

# Add new task
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

# Check result
if [ $? -eq 0 ]; then
    echo "Task successfully added to crontab"
    echo ""
    echo "Current cron tasks:"
    echo "----------------------------------------"
    crontab -l | grep "$UPDATER_SCRIPT"
    echo "----------------------------------------"
    echo ""
    echo "Installation completed successfully!"
    echo ""
    echo "Usage examples:"
    echo "  ./install.sh /etc/podkop/my_sub.txt             # custom sub file, every 12 hours"
    echo "  ./install.sh /root/sub_link 0 */6 * * *         # custom sub file, every 6 hours"
    echo "  ./install.sh /root/sub_link 0 3 * * *           # every day at 3:00"
    echo "  ./install.sh /root/sub_link 0 0 * * 0           # every Sunday at 00:00"
    echo "  ./install.sh /root/sub_link 30 */4 * * *        # every 4 hours at :30"
else
    echo "Error: failed to add task to crontab"
    exit 1
fi

exit 0
