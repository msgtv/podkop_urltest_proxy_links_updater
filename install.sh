#!/bin/sh

# Script to install urltest_proxy_links_updater.sh into OpenWrt crontab
# Default: every 12 hours (0 */12 * * *)

# Path to the updater script
UPDATER_SCRIPT="/root/urltest_proxy_links_updater.sh"
# Path to the subscription file (default)
SUB_FILE="/root/sub_link"

# Help display function
show_help() {
    echo "Install urltest_proxy_links_updater.sh into OpenWrt crontab"
    echo ""
    echo "Usage:"
    echo "  $0 [minutes] [hours] [days] [months] [weekdays]"
    echo "  $0 -h | --help"
    echo ""
    echo "Arguments (cron format):"
    echo "  minutes     0-59 or * (default: 0)"
    echo "  hours       0-23, */N or * (default: */12)"
    echo "  days        1-31 or * (default: *)"
    echo "  months      1-12 or * (default: *)"
    echo "  weekdays    0-7 (0 and 7 = Sunday) or * (default: *)"
    echo ""
    echo "Examples:"
    echo "  $0                            # every 12 hours (default)"
    echo "  $0 0 */6 * * *                # every 6 hours"
    echo "  $0 0 3 * * *                  # every day at 3:00"
    echo "  $0 0 0 * * 0                  # every Sunday at 00:00"
    echo "  $0 30 */4 * * *               # every 4 hours at :30"
    echo "  $0 0 2,14 * * *               # at 2:00 and 14:00 every day"
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
echo "Execution schedule: $CRON_SCHEDULE"
echo "  Minutes:   $CRON_MINUTES"
echo "  Hours:     $CRON_HOURS"
echo "  Days:      $CRON_DAYS"
echo "  Months:    $CRON_MONTHS"
echo "  Weekdays:  $CRON_WEEKDAYS"
echo ""

# Check if updater script exists
if [ ! -f "urltest_proxy_links_updater.sh" ]; then
    echo "Error: urltest_proxy_links_updater.sh not found in current directory"
    exit 1
fi

# Copy script to target directory
echo "Copying script to $UPDATER_SCRIPT..."
cp "urltest_proxy_links_updater.sh" "$UPDATER_SCRIPT"
chmod +x "$UPDATER_SCRIPT"
echo "Script installed: $UPDATER_SCRIPT"
echo ""

# Check if subscription file exists
if [ ! -f "$SUB_FILE" ]; then
    echo "Warning: subscription file $SUB_FILE not found"
    echo "Create it before running the update script"
fi

# Build cron job
# Task will execute the script with the subscription file path
CRON_JOB="$CRON_SCHEDULE $UPDATER_SCRIPT $SUB_FILE"

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
    echo "  ./install.sh                    # every 12 hours (default)"
    echo "  ./install.sh 0 */6 * * *        # every 6 hours"
    echo "  ./install.sh 0 3 * * *          # every day at 3:00"
    echo "  ./install.sh 0 0 * * 0          # every Sunday at 00:00"
    echo "  ./install.sh 30 */4 * * *       # every 4 hours at :30"
else
    echo "Error: failed to add task to crontab"
    exit 1
fi

exit 0
