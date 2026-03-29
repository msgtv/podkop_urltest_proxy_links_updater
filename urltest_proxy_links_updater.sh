#!/bin/sh

# =============================================================================
# urltest_proxy_links_updater.sh
# Downloads subscription links and updates podkop urltest configuration
# =============================================================================

# Temporary files
TMP_RAW="/tmp/sub_raw.txt"
# Podkop service
PODKOP_SERVICE="/etc/init.d/podkop"
# Default subscription file
SUB_FILE="sub_link"

# -----------------------------------------------------------------------------
# Show help message
# -----------------------------------------------------------------------------
show_help() {
    echo "Usage: $0 [subscription_file]"
    echo ""
    echo "Downloads subscription links and updates podkop urltest configuration."
    echo ""
    echo "Arguments:"
    echo "  subscription_file    Path to file containing subscription URL"
    echo "                       (default: sub_link)"
    echo ""
    echo "Options:"
    echo "  -h, --help           Show this help message and exit"
    echo ""
    echo "Example:"
    echo "  $0                   Use default subscription file 'sub_link'"
    echo "  $0 custom_url.txt    Use custom subscription file"
}

# -----------------------------------------------------------------------------
# Check prerequisites: file exists and podkop is in urltest mode
# -----------------------------------------------------------------------------
check_prerequisites() {
    # Check if subscription file exists
    if [ ! -f "$SUB_FILE" ]; then
        echo "Error: File '$SUB_FILE' not found"
        exit 1
    fi

    # Check if podkop is configured for urltest mode
    PROXY_CONFIG_TYPE=$(uci get podkop.@section[0].proxy_config_type 2>/dev/null)

    if [ "$PROXY_CONFIG_TYPE" != "urltest" ]; then
        echo "Error: podkop proxy_config_type is not set to 'urltest' (current value: '$PROXY_CONFIG_TYPE')"
        echo "Please configure podkop to use urltest mode before running this script"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Get HWID: MAC address of br-lan + device model
# -----------------------------------------------------------------------------
get_hwid() {
    local mac model
    mac=$(cat /sys/class/net/br-lan/address 2>/dev/null | tr -d ':')
    if [ -z "$mac" ]; then
        mac=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':')
    fi
    model=$(cat /tmp/sysinfo/model 2>/dev/null | tr -d ' ')
    echo "${mac}_${model}"
}

# -----------------------------------------------------------------------------
# Get HWID encoded in base64
# -----------------------------------------------------------------------------
get_hwid_base64() {
    get_hwid | base64 | tr -d '\n'
}

# -----------------------------------------------------------------------------
# Get OS name from /etc/os-release
# -----------------------------------------------------------------------------
get_os_name() {
    . /etc/os-release 2>/dev/null
    echo "$NAME"
}

# -----------------------------------------------------------------------------
# Get OS version from /etc/os-release
# -----------------------------------------------------------------------------
get_os_version() {
    . /etc/os-release 2>/dev/null
    echo "$VERSION_ID"
}

# -----------------------------------------------------------------------------
# Get device model from /tmp/sysinfo/model
# -----------------------------------------------------------------------------
get_device_model() {
    cat /tmp/sysinfo/model 2>/dev/null
}

# -----------------------------------------------------------------------------
# Build wget headers string
# -----------------------------------------------------------------------------
get_headers() {
    local hwid os_name os_version device_model
    hwid=$(get_hwid)
    os_name=$(get_os_name)
    os_version=$(get_os_version)
    device_model=$(get_device_model)
    
    echo "--header=X-HWID: $hwid"
    echo "--header=X-Device-OS: $os_name"
    echo "--header=X-Ver-OS: $os_version"
    echo "--header=X-Device-Model: $device_model"
    echo "--header=X-App-Version: 1.0"
}

# -----------------------------------------------------------------------------
# Check if content is base64 encoded
# Returns: 0 if base64, 1 otherwise
# -----------------------------------------------------------------------------
is_base64() {
    local content="$1"

    # Base64 strings contain only A-Za-z0-9+/= and no spaces
    # Length should be multiple of 4 or end with padding '='
    if echo "$content" | grep -qE '^[A-Za-z0-9+/]*={0,2}$'; then
        local len=${#content}
        if [ $((len % 4)) -eq 0 ] && [ $len -gt 0 ]; then
            return 0
        fi
    fi

    return 1
}

# -----------------------------------------------------------------------------
# Decode base64 content from file
# Arguments: $1 - input file path
# Returns: 0 on success, 1 on failure
# -----------------------------------------------------------------------------
decode_base64() {
    local input_file="$1"
    local tmp_decoded="/tmp/sub_decoded.txt"
    
    if base64 -d "$input_file" > "$tmp_decoded" 2>/dev/null; then
        if [ -s "$tmp_decoded" ]; then
            mv "$tmp_decoded" "$TMP_RAW"
            return 0
        fi
    fi
    
    rm -f "$tmp_decoded" 2>/dev/null
    return 1
}

# -----------------------------------------------------------------------------
# Download subscription from URL
# Returns: sets URLTEST_PROXY_LINKS and COUNT variables
# -----------------------------------------------------------------------------
download_subscription() {
    # Read the subscription URL
    SUB_URL=$(cat "$SUB_FILE" | tr -d '\r\n')

    if [ -z "$SUB_URL" ]; then
        echo "Error: Subscription URL is empty"
        exit 1
    fi

    echo "Requesting $SUB_URL"

    # Get header values
    local hwid os_name os_version device_model
    hwid=$(get_hwid_base64)
    os_name=$(get_os_name)
    os_version=$(get_os_version)
    device_model=$(get_device_model)

    # Download subscription with headers using wget --header
    wget -q -O "$TMP_RAW" \
        --header="X-HWID: $hwid" \
        --header="X-Device-OS: $os_name" \
        --header="X-Ver-OS: $os_version" \
        --header="X-Device-Model: $device_model" \
        --header="X-App-Version: 1.0" \
        "$SUB_URL"

    if [ $? -ne 0 ]; then
        echo "Error: failed to download subscription"
        exit 1
    fi

    # Check if downloaded file is empty
    if [ ! -s "$TMP_RAW" ]; then
        echo "Error: downloaded subscription file is empty"
        exit 1
    fi

    # Check if content is base64 encoded and decode if necessary
    local raw_content
    raw_content=$(cat "$TMP_RAW" | tr -d '\r\n')

    if is_base64 "$raw_content"; then
        echo "Detected base64 encoded content, decoding..."
        if decode_base64 "$TMP_RAW"; then
            echo "Base64 decoding successful"
        else
            echo "Warning: base64 decoding failed, using original content"
        fi
    fi

    COUNT=$(wc -l < $TMP_RAW)

    echo "Found $COUNT configs"
    echo "Saved to $TMP_RAW"
}

# -----------------------------------------------------------------------------
# Update podkop configuration with new links
# -----------------------------------------------------------------------------
update_podkop_config() {
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
}

# -----------------------------------------------------------------------------
# Main function
# -----------------------------------------------------------------------------
main() {
    # Parse command line arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                SUB_FILE="$1"
                echo "Using file from argument: $SUB_FILE"
                ;;
        esac
        shift
    done

    # If no argument was provided, use default
    if [ -z "$SUB_FILE" ]; then
        SUB_FILE="sub_link"
    fi

    if [ "$SUB_FILE" = "sub_link" ]; then
        echo "Using default file: $SUB_FILE"
    fi

    # Run main workflow
    check_prerequisites
    download_subscription
    update_podkop_config

    exit 0
}

# Run main function with all arguments
main "$@"
