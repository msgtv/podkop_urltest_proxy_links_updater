#!/bin/sh

# Subscription file: default "sub_link", can be overridden via command line argument
SUB_FILE="sub_link"
if [ -n "$1" ]; then
    SUB_FILE="$1"
    echo "Using file from argument: $SUB_FILE"
else
    echo "Using default file: $SUB_FILE"
fi
# Temporary files
TMP_RAW="/tmp/sub_raw.txt"
# Podkop service
PODKOP_SERVICE="/etc/init.d/podkop"

# Check if podkop is configured for urltest mode
PROXY_CONFIG_TYPE=$(uci get podkop.@section[0].proxy_config_type 2>/dev/null)

if [ "$PROXY_CONFIG_TYPE" != "urltest" ]; then
    echo "Error: podkop proxy_config_type is not set to 'urltest' (current value: '$PROXY_CONFIG_TYPE')"
    echo "Please configure podkop to use urltest mode before running this script"
    exit 1
fi

# Check if file exists
if [ ! -f "$SUB_FILE" ]; then
    echo "File $SUB_FILE not found"
    exit 1
fi

# Read the subscription URL
SUB_URL=$(cat "$SUB_FILE" | tr -d '\r\n')

if [ -z "$SUB_URL" ]; then
    echo "Subscription URL is empty"
    exit 1
fi

echo "Requesting $SUB_URL"

# Download subscription
wget -q -O "$TMP_RAW" "$SUB_URL"

if [ $? -ne 0 ]; then
    echo "Error downloading subscription"
    exit 1
fi


# Check if downloaded file is empty
if [ ! -s "$TMP_RAW" ]; then
    echo "Error: downloaded subscription file is empty"
    exit 1
fi

COUNT=$(wc -l < $TMP_RAW)

echo "Found $COUNT configs"
echo "Saved to $TMP_RAW"

# Update configs in podkop
# Convert multiline file to single line (replace \n with spaces)
# This is required for uci which does not support multiline values
URLTEST_PROXY_LINKS=$(tr '\n' ' ' < $TMP_RAW)

echo "Character count in downloaded string: ${#URLTEST_PROXY_LINKS}"

# Get current value from uci
CURRENT_PROXY_LINKS=$(uci get podkop.@section[0].urltest_proxy_links 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "Warning: could not get current proxy links from uci"
    CURRENT_PROXY_LINKS=""
fi

# Compare new and current values
if [ "$URLTEST_PROXY_LINKS" = "$CURRENT_PROXY_LINKS" ]; then
    echo "No changes detected - subscription links are identical"
    echo "Skipping update and restart"
    exit 0
fi

echo "Changes detected - updating podkop configuration..."

# Set urltest_proxy_links value in podkop configuration
uci set podkop.@section[0].urltest_proxy_links="$URLTEST_PROXY_LINKS"

# Check if configuration was applied successfully
if [ $? -eq 0 ]; then
    echo "Podkop configuration updated successfully"
    $PODKOP_SERVICE restart
else
    echo "Error: failed to update podkop configuration"
    exit 1
fi

exit 0