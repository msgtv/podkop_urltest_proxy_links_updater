#!/bin/sh

# =============================================================================
# urltest_proxy_links_updater.sh
# Downloads subscription links and updates podkop urltest configuration
# =============================================================================

# Temporary files
TMP_RAW="/tmp/sub_raw.txt"
TMP_VALID="/tmp/sub_valid.txt"
# Podkop service
PODKOP_SERVICE="/etc/init.d/podkop"
# Default subscription file
SUB_FILE="sub_link"

# Statistics counters
VALID_COUNT=0
INVALID_COUNT=0

# Filter pattern for config names (case-insensitive)
FILTER_NAME_PATTERN="LTE"

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
# Check if content is base64 encoded
# Returns: 0 if base64, 1 otherwise
# -----------------------------------------------------------------------------
is_base64() {
    local content="$1"

    # Quick check: If there are typical proxy URL characters, it is not base64.
    if echo "$content" | grep -qE '://|@'; then
        return 1
    fi

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
# Validate IPv4 address
# Arguments: $1 - IP address
# Returns: 0 if valid, 1 if invalid
# -----------------------------------------------------------------------------
validate_ipv4() {
    local ip="$1"
    local o1 o2 o3 o4
    
    # Check format: X.X.X.X
    if ! echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        return 1
    fi
    
    # Split into octets using awk
    o1=$(echo "$ip" | awk -F. '{print $1}')
    o2=$(echo "$ip" | awk -F. '{print $2}')
    o3=$(echo "$ip" | awk -F. '{print $3}')
    o4=$(echo "$ip" | awk -F. '{print $4}')
    
    # Check each octet
    for octet in $o1 $o2 $o3 $o4; do
        # Check for leading zeros (except single "0")
        if echo "$octet" | grep -qE '^0[0-9]'; then
            return 1
        fi
        # Check if it's a valid number
        if ! echo "$octet" | grep -qE '^[0-9]+$'; then
            return 1
        fi
        # Check range 0-255
        if [ "$octet" -lt 0 ] 2>/dev/null || [ "$octet" -gt 255 ] 2>/dev/null; then
            return 1
        fi
    done
    
    return 0
}

# -----------------------------------------------------------------------------
# Validate domain name
# Arguments: $1 - domain name
# Returns: 0 if valid, 1 if invalid
# -----------------------------------------------------------------------------
validate_domain() {
    local domain="$1"
    
    # Empty domain is invalid
    if [ -z "$domain" ]; then return 1; fi
    
    # Check length (max 253 chars)
    if [ ${#domain} -gt 253 ]; then return 1; fi

    # Check allowed characters: a-z, A-Z, 0-9, -, .
    if ! echo "$domain" | grep -qE '^[a-zA-Z0-9.-]+$'; then return 1; fi

    # Check doesn't start or end with hyphen
    if echo "$domain" | grep -qE '^-|-$'; then
        return 1
    fi

    # double dots check
    if echo "$domain" | grep -qE '\.\.'; then
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Validate port number (1-65535)
# Arguments: $1 - port number
# Returns: 0 if valid, 1 if invalid
# -----------------------------------------------------------------------------
validate_port() {
    local port="$1"
    
    # Check if it's a valid number
    if ! echo "$port" | grep -qE '^[0-9]+$'; then
        return 1
    fi
    
    # Check range 1-65535
    if [ "$port" -lt 1 ] 2>/dev/null || [ "$port" -gt 65535 ] 2>/dev/null; then
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Extract host from URL (between :// and :port or /path or ?query or end)
# Arguments: $1 - URL without scheme
# Returns: host via stdout
# -----------------------------------------------------------------------------
extract_host() {
    local url_part="$1"
    local host
    
    # Remove path (everything after first /)
    host=$(echo "$url_part" | sed 's|/.*||')
    # Remove port (everything after last :)
    host=$(echo "$host" | sed 's|:[^:]*$||')
    # Remove userinfo (everything before @)
    host=$(echo "$host" | sed 's|^[^@]*@||')
    
    echo "$host"
}

# -----------------------------------------------------------------------------
# Extract port from URL
# Arguments: $1 - URL without scheme
# Returns: port via stdout or empty if no port
# -----------------------------------------------------------------------------
extract_port() {
    local url_part="$1"
    local port
    
    # Remove path and query first
    url_part=$(echo "$url_part" | sed 's|[/?].*||')
    
    # Extract port (after last :)
    if echo "$url_part" | grep -qE ':[0-9]+$'; then
        port=$(echo "$url_part" | sed 's|.*:||')
        echo "$port"
    fi
}

# -----------------------------------------------------------------------------
# Validate Shadowsocks URL (ss://)
# Arguments: $1 - full URL
# Returns: 0 if valid, 1 if invalid
# -----------------------------------------------------------------------------
validate_shadowsocks_url() {
    local url="$1"
    local url_part host port
    
    # Must start with ss://
    if ! echo "$url" | grep -qE '^ss://'; then
        echo "Invalid Shadowsocks URL: missing ss:// prefix" >&2
        return 1
    fi
    
    # Check for spaces
    if echo "$url" | grep -q ' '; then
        echo "Invalid Shadowsocks URL: contains spaces" >&2
        return 1
    fi
    
    # Get part after ss://
    url_part=$(echo "$url" | sed 's|^ss://||')
    
    # Must have content
    if [ -z "$url_part" ]; then
        echo "Invalid Shadowsocks URL: empty after ss://" >&2
        return 1
    fi
    
    # Extract host and port
    host=$(extract_host "$url_part")
    port=$(extract_port "$url_part")
    
    # Must have host
    if [ -z "$host" ]; then
        echo "Invalid Shadowsocks URL: missing host" >&2
        return 1
    fi
    
    # Must have port
    if [ -z "$port" ]; then
        echo "Invalid Shadowsocks URL: missing port" >&2
        return 1
    fi
    
    # Validate port
    if ! validate_port "$port"; then
        echo "Invalid Shadowsocks URL: invalid port number" >&2
        return 1
    fi
    
    # Validate host (IPv4 or domain)
    if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        if ! validate_ipv4 "$host"; then
            echo "Invalid Shadowsocks URL: invalid IPv4 address" >&2
            return 1
        fi
    else
        if ! validate_domain "$host"; then
            echo "Invalid Shadowsocks URL: invalid domain" >&2
            return 1
        fi
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Validate VLESS URL (vless://)
# Arguments: $1 - full URL
# Returns: 0 if valid, 1 if invalid
# -----------------------------------------------------------------------------
validate_vless_url() {
    local url="$1"
    local url_part host port query uuid
    
    # Must start with vless://
    if ! echo "$url" | grep -qE '^vless://'; then
        echo "Invalid VLESS URL: missing vless:// prefix" >&2
        return 1
    fi
    
    # Check for spaces
    if echo "$url" | grep -q ' '; then
        echo "Invalid VLESS URL: contains spaces" >&2
        return 1
    fi
    
    # Get part after vless://
    url_part=$(echo "$url" | sed 's|^vless://||')
    
    # Must have content
    if [ -z "$url_part" ]; then
        echo "Invalid VLESS URL: empty after vless://" >&2
        return 1
    fi
    
    # Extract UUID (before @)
    uuid=$(echo "$url_part" | sed 's|@.*||')
    if [ -z "$uuid" ] || [ "$uuid" = "$url_part" ]; then
        echo "Invalid VLESS URL: missing UUID" >&2
        return 1
    fi
    
    # Get part after @
    url_part=$(echo "$url_part" | sed 's|^[^@]*@||')
    
    # Extract host and port
    host=$(extract_host "$url_part")
    port=$(extract_port "$url_part")
    
    # Must have host
    if [ -z "$host" ]; then
        echo "Invalid VLESS URL: missing host" >&2
        return 1
    fi
    
    # Must have port
    if [ -z "$port" ]; then
        echo "Invalid VLESS URL: missing port" >&2
        return 1
    fi
    
    # Validate port
    if ! validate_port "$port"; then
        echo "Invalid VLESS URL: invalid port number" >&2
        return 1
    fi
    
    # Validate host
    if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        if ! validate_ipv4 "$host"; then
            echo "Invalid VLESS URL: invalid IPv4 address" >&2
            return 1
        fi
    else
        if ! validate_domain "$host"; then
            echo "Invalid VLESS URL: invalid domain" >&2
            return 1
        fi
    fi
    
    # Must have query parameters
    if ! echo "$url" | grep -qE '\?'; then
        echo "Invalid VLESS URL: missing query parameters" >&2
        return 1
    fi
    
    # Extract query string
    query=$(echo "$url" | sed 's|^[^?]*?||')
    
    # Check for supported type parameter
    if echo "$query" | grep -qE 'type='; then
        local vtype
        vtype=$(echo "$query" | sed 's|.*type=\([^&]*\).*|\1|')
        case "$vtype" in
            tcp|raw|udp|grpc|http|httpupgrade|xhttp|ws|kcp) ;;
            *)
                echo "Invalid VLESS URL: unsupported type=$vtype" >&2
                return 1
                ;;
        esac
    fi
    
    # Check for supported security parameter
    if echo "$query" | grep -qE 'security='; then
        local security
        security=$(echo "$query" | sed 's|.*security=\([^&]*\).*|\1|')
        case "$security" in
            tls|reality|none) ;;
            *)
                echo "Invalid VLESS URL: unsupported security=$security" >&2
                return 1
                ;;
        esac
        
        # For reality, check pbk and fp have non-empty values
        if [ "$security" = "reality" ]; then
            local pbk_value fp_value
            pbk_value=$(echo "$query" | sed -n 's/.*pbk=\([^&]*\).*/\1/p')
            if [ -z "$pbk_value" ]; then
                echo "Invalid VLESS URL: reality security requires non-empty pbk parameter" >&2
                return 1
            fi
            fp_value=$(echo "$query" | sed -n 's/.*fp=\([^&]*\).*/\1/p')
            if [ -z "$fp_value" ]; then
                echo "Invalid VLESS URL: reality security requires non-empty fp parameter" >&2
                return 1
            fi
        fi
    fi
    
    # Check for unsupported flow
    if echo "$query" | grep -qE 'flow=xtls-rprx-vision-udp443'; then
        echo "Invalid VLESS URL: unsupported flow=xtls-rprx-vision-udp443" >&2
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Validate Trojan URL (trojan://)
# Arguments: $1 - full URL
# Returns: 0 if valid, 1 if invalid
# -----------------------------------------------------------------------------
validate_trojan_url() {
    local url="$1"
    local url_part host port password
    
    # Must start with trojan://
    if ! echo "$url" | grep -qE '^trojan://'; then
        echo "Invalid Trojan URL: missing trojan:// prefix" >&2
        return 1
    fi
    
    # Check for spaces
    if echo "$url" | grep -q ' '; then
        echo "Invalid Trojan URL: contains spaces" >&2
        return 1
    fi
    
    # Get part after trojan://
    url_part=$(echo "$url" | sed 's|^trojan://||')
    
    # Must have content
    if [ -z "$url_part" ]; then
        echo "Invalid Trojan URL: empty after trojan://" >&2
        return 1
    fi
    
    # Extract password (before @)
    password=$(echo "$url_part" | sed 's|@.*||')
    if [ -z "$password" ] || [ "$password" = "$url_part" ]; then
        echo "Invalid Trojan URL: missing password" >&2
        return 1
    fi
    
    # Get part after @
    url_part=$(echo "$url_part" | sed 's|^[^@]*@||')
    
    # Extract host and port
    host=$(extract_host "$url_part")
    port=$(extract_port "$url_part")
    
    # Must have host
    if [ -z "$host" ]; then
        echo "Invalid Trojan URL: missing host" >&2
        return 1
    fi
    
    # Must have port
    if [ -z "$port" ]; then
        echo "Invalid Trojan URL: missing port" >&2
        return 1
    fi
    
    # Validate port
    if ! validate_port "$port"; then
        echo "Invalid Trojan URL: invalid port number" >&2
        return 1
    fi
    
    # Validate host
    if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        if ! validate_ipv4 "$host"; then
            echo "Invalid Trojan URL: invalid IPv4 address" >&2
            return 1
        fi
    else
        if ! validate_domain "$host"; then
            echo "Invalid Trojan URL: invalid domain" >&2
            return 1
        fi
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Validate SOCKS URL (socks4://, socks4a://, socks5://)
# Arguments: $1 - full URL
# Returns: 0 if valid, 1 if invalid
# -----------------------------------------------------------------------------
validate_socks_url() {
    local url="$1"
    local url_part host port scheme
    
    # Must start with socks4://, socks4a://, or socks5://
    if ! echo "$url" | grep -qE '^socks[45]a?://'; then
        echo "Invalid SOCKS URL: missing socks4/4a/5:// prefix" >&2
        return 1
    fi
    
    # Check for spaces
    if echo "$url" | grep -q ' '; then
        echo "Invalid SOCKS URL: contains spaces" >&2
        return 1
    fi
    
    # Get scheme and part after ://
    scheme=$(echo "$url" | sed 's|://.*||')
    url_part=$(echo "$url" | sed "s|^$scheme://||")
    
    # Must have content
    if [ -z "$url_part" ]; then
        echo "Invalid SOCKS URL: empty after $scheme://" >&2
        return 1
    fi
    
    # Extract host and port
    host=$(extract_host "$url_part")
    port=$(extract_port "$url_part")
    
    # Must have host
    if [ -z "$host" ]; then
        echo "Invalid SOCKS URL: missing host" >&2
        return 1
    fi
    
    # Must have port
    if [ -z "$port" ]; then
        echo "Invalid SOCKS URL: missing port" >&2
        return 1
    fi
    
    # Validate port
    if ! validate_port "$port"; then
        echo "Invalid SOCKS URL: invalid port number" >&2
        return 1
    fi
    
    # Validate host (IPv4 or domain)
    if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        if ! validate_ipv4 "$host"; then
            echo "Invalid SOCKS URL: invalid IPv4 address" >&2
            return 1
        fi
    else
        if ! validate_domain "$host"; then
            echo "Invalid SOCKS URL: invalid domain" >&2
            return 1
        fi
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Validate Hysteria2 URL (hysteria2:// or hy2://)
# Arguments: $1 - full URL
# Returns: 0 if valid, 1 if invalid
# -----------------------------------------------------------------------------
validate_hysteria2_url() {
    local url="$1"
    local url_part host port password query scheme
    
    # Must start with hysteria2:// or hy2://
    if ! echo "$url" | grep -qE '^hysteria2://|^hy2://'; then
        echo "Invalid Hysteria2 URL: missing hysteria2:// or hy2:// prefix" >&2
        return 1
    fi
    
    # Check for spaces
    if echo "$url" | grep -q ' '; then
        echo "Invalid Hysteria2 URL: contains spaces" >&2
        return 1
    fi
    
    # Get scheme and part after ://
    scheme=$(echo "$url" | sed 's|://.*||')
    url_part=$(echo "$url" | sed "s|^$scheme://||")
    
    # Must have content
    if [ -z "$url_part" ]; then
        echo "Invalid Hysteria2 URL: empty after $scheme://" >&2
        return 1
    fi
    
    # Extract password (before @)
    password=$(echo "$url_part" | sed 's|@.*||')
    if [ -z "$password" ] || [ "$password" = "$url_part" ]; then
        echo "Invalid Hysteria2 URL: missing password" >&2
        return 1
    fi
    
    # Get part after @
    url_part=$(echo "$url_part" | sed 's|^[^@]*@||')
    
    # Extract host and port
    host=$(extract_host "$url_part")
    port=$(extract_port "$url_part")
    
    # Must have host
    if [ -z "$host" ]; then
        echo "Invalid Hysteria2 URL: missing host" >&2
        return 1
    fi
    
    # Must have port
    if [ -z "$port" ]; then
        echo "Invalid Hysteria2 URL: missing port" >&2
        return 1
    fi
    
    # Validate port
    if ! validate_port "$port"; then
        echo "Invalid Hysteria2 URL: invalid port number" >&2
        return 1
    fi
    
    # Validate host
    if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        if ! validate_ipv4 "$host"; then
            echo "Invalid Hysteria2 URL: invalid IPv4 address" >&2
            return 1
        fi
    else
        if ! validate_domain "$host"; then
            echo "Invalid Hysteria2 URL: invalid domain" >&2
            return 1
        fi
    fi
    
    # Check query parameters if present
    if echo "$url" | grep -qE '\?'; then
        query=$(echo "$url" | sed 's|^[^?]*?||')
        
        # Check insecure parameter (must be 0 or 1)
        if echo "$query" | grep -qE 'insecure='; then
            local insecure
            insecure=$(echo "$query" | sed 's|.*insecure=\([^&]*\).*|\1|')
            if [ "$insecure" != "0" ] && [ "$insecure" != "1" ]; then
                echo "Invalid Hysteria2 URL: insecure must be 0 or 1" >&2
                return 1
            fi
        fi
        
        # Check obfs parameter
        if echo "$query" | grep -qE 'obfs='; then
            local obfs
            obfs=$(echo "$query" | sed 's|.*obfs=\([^&]*\).*|\1|')
            case "$obfs" in
                none|salamander) ;;
                *)
                    echo "Invalid Hysteria2 URL: unsupported obfs=$obfs" >&2
                    return 1
                    ;;
            esac
            
            # If obfs != none, require non-empty obfs-password
            if [ "$obfs" != "none" ]; then
                local obfs_password_value
                obfs_password_value=$(echo "$query" | sed -n 's/.*obfs-password=\([^&]*\).*/\1/p')
                if [ -z "$obfs_password_value" ]; then
                    echo "Invalid Hysteria2 URL: obfs=$obfs requires non-empty obfs-password parameter" >&2
                    return 1
                fi
            fi
        fi
        
        # Check sni parameter (cannot be empty)
        if echo "$query" | grep -qE 'sni='; then
            local sni_value
            sni_value=$(echo "$query" | sed -n 's/.*sni=\([^&]*\).*/\1/p')
            if [ -z "$sni_value" ]; then
                echo "Invalid Hysteria2 URL: sni cannot be empty" >&2
                return 1
            fi
        fi
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Validate proxy URL (main dispatcher function)
# Arguments: $1 - full URL
# Returns: 0 if valid, 1 if invalid
# -----------------------------------------------------------------------------
validate_proxy_url() {
    local url="$1"
    
    # Check for empty or whitespace-only
    if [ -z "$url" ] || echo "$url" | grep -qE '^[[:space:]]*$'; then
        echo "Empty or whitespace-only line" >&2
        return 1
    fi
    
    # Trim leading/trailing whitespace
    url=$(echo "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Skip comment lines
    if echo "$url" | grep -qE '^#'; then
        echo "Comment line skipped" >&2
        return 1
    fi
    
    # Determine protocol and call appropriate validator
    if echo "$url" | grep -qE '^ss://'; then
        validate_shadowsocks_url "$url"
        return $?
    elif echo "$url" | grep -qE '^vless://'; then
        validate_vless_url "$url"
        return $?
    elif echo "$url" | grep -qE '^trojan://'; then
        validate_trojan_url "$url"
        return $?
    elif echo "$url" | grep -qE '^socks4a?://|^socks5://'; then
        validate_socks_url "$url"
        return $?
    elif echo "$url" | grep -qE '^hysteria2://|^hy2://'; then
        validate_hysteria2_url "$url"
        return $?
    else
        echo "Unsupported protocol scheme" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Check if config name contains the filter pattern (case-insensitive)
# Arguments: $1 - full URL
# Returns: 0 if should be filtered out, 1 if should be kept
# -----------------------------------------------------------------------------
should_filter_by_name() {
    local url="$1"
    local name

    # Extract name (everything after #)
    if ! echo "$url" | grep -q '#'; then
        # No name present, don't filter
        return 1
    fi

    name=$(echo "$url" | sed 's/^[^#]*#//')

    # Check if name contains the filter pattern (case-insensitive)
    if echo "$name" | grep -qi "$FILTER_NAME_PATTERN"; then
        return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# Filter valid links from input
# Reads from stdin
# Outputs valid links to stdout
# Outputs logs and statistics to stderr
# -----------------------------------------------------------------------------
filter_valid_links() {
    local line
    local error_msg
    local total=0
    local valid=0
    local invalid=0
    local filtered_by_name=0
    local ret

    echo "Validating proxy URLs..." >&2

    # Clear valid links file
    : > "$TMP_VALID"

    while IFS= read -r line || [ -n "$line" ]; do
        total=$((total + 1))

        # Trim whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines
        if [ -z "$line" ]; then
            total=$((total - 1))
            continue
        fi

        # Skip comment lines
        if echo "$line" | grep -qE '^#'; then
            invalid=$((invalid + 1))
            echo "[INVALID] $line - comment line" >&2
            continue
        fi

        # Validate URL (capture stderr, check exit code)
        error_msg=$(validate_proxy_url "$line" 2>&1)
        ret=$?
        if [ $ret -eq 0 ]; then
            # Check if config name should be filtered
            if should_filter_by_name "$line"; then
                filtered_by_name=$((filtered_by_name + 1))
                echo "[FILTERED] $line - name contains '$FILTER_NAME_PATTERN'" >&2
            else
                echo "$line" >> "$TMP_VALID"
                echo "[VALID] $line" >&2
                valid=$((valid + 1))
            fi
        else
            invalid=$((invalid + 1))
            echo "[INVALID] $line - $error_msg" >&2
        fi
    done

    # Update global counters
    VALID_COUNT=$valid
    INVALID_COUNT=$invalid

    # Output statistics
    echo "[STATS] Total: $total, Valid: $valid, Filtered: $filtered_by_name, Invalid: $invalid" >&2
    echo "Filtered valid links saved to $TMP_VALID" >&2

    # Output valid links to stdout
    cat "$TMP_VALID"
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
    raw_content=$(tr -d '\r\n' < "$TMP_RAW")

    if is_base64 "$raw_content"; then
        echo "Detected base64 encoded content, decoding..."
        if decode_base64 "$TMP_RAW"; then
            echo "Base64 decoding successful"
        else
            echo "Warning: base64 decoding failed, using original content"
        fi
    fi

    COUNT=$(wc -l < "$TMP_RAW")

    echo "Found $COUNT configs"
    echo "Saved to $TMP_RAW"
    
    # Filter valid links and update TMP_RAW with only valid URLs
    filter_valid_links < "$TMP_RAW" > "${TMP_RAW}.filtered"
    mv "${TMP_RAW}.filtered" "$TMP_RAW"
    
    # Update COUNT with valid links count
    COUNT=$(wc -l < "$TMP_RAW")
    echo "Valid links after filtering: $COUNT"
}

# -----------------------------------------------------------------------------
# Update podkop configuration with new links using uci batch add_list
# -----------------------------------------------------------------------------
update_podkop_config() {
    # Read valid links from file
    local links_file="$TMP_RAW"
    
    # Check if file is empty
    if [ ! -s "$links_file" ]; then
        echo "Error: no valid proxy links found after filtering"
        echo "Skipping update - configuration unchanged"
        exit 1
    fi

    # Get current value from uci
    local current_links
    current_links=$(uci get podkop.@section[0].urltest_proxy_links 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "Warning: could not get current proxy links from uci"
        current_links=""
    fi

    # Build uci batch commands and calculate new links hash
    local uci_commands=""
    local first=1
    local line_count=0
    local new_links_hash=""
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines
        [ -z "$line" ] && continue
        
        line_count=$((line_count + 1))
        
        # Build hash for comparison (concatenate all links)
        new_links_hash="${new_links_hash}${line}|"
        
        if [ $first -eq 1 ]; then
            # First link uses 'set'
            uci_commands="${uci_commands}set podkop.@section[0].urltest_proxy_links='$line'
"
            first=0
        else
            # Subsequent links use 'add_list'
            uci_commands="${uci_commands}add_list podkop.@section[0].urltest_proxy_links='$line'
"
        fi
    done < "$links_file"
    
    # Add commit command
    uci_commands="${uci_commands}commit podkop"

    echo "Found $line_count links to configure"

    # Check if we have any links
    if [ $line_count -eq 0 ]; then
        echo "Error: no valid proxy links to configure"
        exit 1
    fi

    # Build current links hash for comparison
    local current_links_hash=""
    if [ -n "$current_links" ]; then
        # Convert space-separated to pipe-separated for consistent comparison
        current_links_hash=$(echo "$current_links" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' '|' | sed 's/|$//')
    fi
    
    # Sort new links for comparison
    local new_links_sorted
    new_links_sorted=$(echo "$new_links_hash" | tr '|' '\n' | grep -v '^$' | sort | tr '\n' '|' | sed 's/|$//')

    # Compare hashes (content check)
    if [ "$current_links_hash" = "$new_links_sorted" ]; then
        echo "No changes detected - subscription links are identical"
        echo "Skipping update and restart"
        exit 0
    fi

    echo "Changes detected - updating podkop configuration..."

    # Execute uci batch commands
    echo "$uci_commands" | uci batch

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
