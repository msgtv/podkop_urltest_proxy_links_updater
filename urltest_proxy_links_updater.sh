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
# sing-box health check settings
# -----------------------------------------------------------------------------
# Path to the sing-box config generated/used by podkop.
# Set to empty string to skip config-file validation step.
SINGBOX_CONFIG_PATH="/etc/sing-box/config.json"

# URL used for the connectivity probe.
# Default: https://instagram.com — a domain that is NOT reachable directly
# from Russian/CIS ISPs, so a successful probe guarantees that traffic is
# actually going through the proxy. (Cloudflare/gstatic generate_204 are
# reachable directly from the WAN, which causes false positives on routers
# where TUN/tproxy rules are not in place.)
SINGBOX_CHECK_URL="https://instagram.com"
# Timeout (seconds) for a single probe attempt.
SINGBOX_CHECK_TIMEOUT="15"
# Number of retries before declaring sing-box unhealthy.
# Total worst-case probe time ≈ retries × timeout.
SINGBOX_CHECK_RETRIES="2"
# Optional explicit proxy for the probe, e.g. "http://127.0.0.1:1080"
# or "socks5://127.0.0.1:1080". Leave empty to AUTO-DETECT from the
# sing-box config file: the script parses inbounds and picks:
#   - http/mixed     → http://127.0.0.1:<listen_port>
#   - socks          → socks5://127.0.0.1:<listen_port>
#   - tun/tproxy     → direct request (transparent mode)
# Priority: http/mixed > socks > tun/tproxy.
# Set this variable to a non-empty value to override auto-detection.
SINGBOX_CHECK_PROXY=""
# Set to 1 via --force to skip the sing-box health check entirely.
SKIP_SINGBOX_CHECK=0

# -----------------------------------------------------------------------------
# Show help message
# -----------------------------------------------------------------------------
show_help() {
    echo "Usage: $0 [options] [subscription_file]"
    echo ""
    echo "Downloads subscription links and updates podkop urltest configuration."
    echo ""
    echo "Before downloading, the script checks whether the current sing-box"
    echo "instance is healthy (process up, config valid, connectivity OK)."
    echo "If sing-box is healthy, the script exits without downloading anything."
    echo ""
    echo "Arguments:"
    echo "  subscription_file    Path to file containing subscription URL"
    echo "                       (default: sub_link)"
    echo ""
    echo "Options:"
    echo "  -h, --help           Show this help message and exit"
    echo "  -f, --force          Skip the sing-box health check and always"
    echo "                       download / update configs"
    echo ""
    echo "Example:"
    echo "  $0                   Use default subscription file 'sub_link'"
    echo "  $0 custom_url.txt    Use custom subscription file"
    echo "  $0 --force           Skip sing-box check, force re-download"
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
# Auto-detect a probe proxy URL from the sing-box config file.
# Reads the "inbounds" array of $SINGBOX_CONFIG_PATH and selects:
#   - http/mixed inbound → http://<listen>:<listen_port>
#   - socks inbound      → socks5://<listen>:<listen_port>
#   - tun/tproxy inbound → empty string (direct request, transparent mode)
# Priority: http/mixed > socks > tun/tproxy (direct).
# The mixed/http inbound is preferred because it provides an explicit,
# reliable path that does not depend on iptables/nftables rules being
# in place (which tun/tproxy do).
# Outputs the chosen URL (or empty string for direct mode) on stdout.
# Returns: 0 if a decision was made, 1 if config could not be parsed
#          or no usable inbound was found.
# -----------------------------------------------------------------------------
detect_singbox_check_proxy() {
    local config="$SINGBOX_CONFIG_PATH"

    # Need a config file to inspect
    if [ -z "$config" ] || [ ! -f "$config" ]; then
        return 1
    fi

    # jshn is shipped with libubox (a hard dependency of podkop / OpenWrt base)
    # Allow override of the shim path for testing.
    local jshn_path="${JSHN_SH:-/usr/share/libubox/jshn.sh}"
    if [ ! -f "$jshn_path" ]; then
        echo "[WARN] jshn.sh not found ($jshn_path) — cannot parse $config" >&2
        return 1
    fi
    . "$jshn_path"

    if ! json_load "$(cat "$config")" 2>/dev/null; then
        echo "[WARN] failed to parse $config as JSON" >&2
        json_cleanup 2>/dev/null
        return 1
    fi

    # "inbounds" must exist and be an array
    if ! json_is_a "inbounds" array 2>/dev/null; then
        echo "[WARN] no 'inbounds' array in $config" >&2
        json_cleanup
        return 1
    fi

    json_select "inbounds" 2>/dev/null || {
        json_cleanup
        return 1
    }

    # Standard jshn idiom: get all keys (numeric indices for arrays) and
    # iterate. This is more portable than probing json_is_a "<idx>" object
    # in a while loop, which behaves inconsistently across jshn versions.
    local keys
    json_get_keys keys 2>/dev/null

    local found_transparent=0
    local found_http_proxy=""
    local found_socks_proxy=""

    local k
    for k in $keys; do
        if ! json_select "$k" 2>/dev/null; then
            continue
        fi

        local itype listen lport
        json_get_var itype "type" 2>/dev/null
        json_get_var listen "listen" 2>/dev/null
        json_get_var lport "listen_port" 2>/dev/null

        # Normalize listen address
        [ -z "$listen" ] && listen="127.0.0.1"
        case "$listen" in
            0.0.0.0|::|\[::\]|"::1") listen="127.0.0.1" ;;
        esac
        # Bracket IPv6 addresses for use in URLs
        case "$listen" in
            *:*) listen="[$listen]" ;;
        esac

        case "$itype" in
            tun|tproxy)
                # Transparent modes: rely on kernel-level traffic interception
                # (tun interface or tproxy iptables/nftables rules).
                found_transparent=1
                ;;
            http|mixed)
                # Mixed serves both HTTP and SOCKS; wget speaks HTTP, so use http://
                [ -z "$found_http_proxy" ] && [ -n "$lport" ] && \
                    found_http_proxy="http://${listen}:${lport}"
                ;;
            socks)
                [ -z "$found_socks_proxy" ] && [ -n "$lport" ] && \
                    found_socks_proxy="socks5://${listen}:${lport}"
                ;;
        esac

        json_select ".." 2>/dev/null
    done

    json_select ".." 2>/dev/null
    json_cleanup

    # Priority: explicit http/mixed > socks > transparent (tun/tproxy)
    if [ -n "$found_http_proxy" ]; then
        echo "$found_http_proxy"
        return 0
    fi
    if [ -n "$found_socks_proxy" ]; then
        echo "$found_socks_proxy"
        return 0
    fi
    if [ $found_transparent -eq 1 ]; then
        # Empty string signals direct mode (transparent interception).
        echo ""
        return 0
    fi

    # No usable inbound found
    return 1
}

# -----------------------------------------------------------------------------
# Perform a single HTTP connectivity probe to a given URL.
#
# Why this function exists:
#   BusyBox wget (versions ≤ 1.36) has a known bug where it returns a
#   non-zero exit code on HTTP 204 / 200-with-empty-body responses,
#   because it tries to read the body and times out even though the
#   request actually succeeded. This causes false-negative health-check
#   failures on OpenWrt routers that ship BusyBox wget.
#
# Strategy (in order of preference):
#   1. curl   — handles 204 correctly, supports --proxy for both http and
#               socks5 URLs, returns exit code 0 on any 2xx/3xx by default.
#   2. wget   — parse the HTTP status code from the --server-response
#               header output instead of trusting the exit code. A 2xx or
#               3xx status line is treated as success. Works on both GNU
#               wget and BusyBox wget (both support -S / --server-response).
#
# Arguments:
#   $1 - URL to probe
#   $2 - proxy URL (may be empty for direct request)
#   $3 - timeout in seconds
# Returns: 0 if the probe succeeded (2xx/3xx response), 1 otherwise
# -----------------------------------------------------------------------------
probe_http() {
    local url="$1"
    local proxy="$2"
    local timeout="$3"

    # User-Agent: Instagram blocks requests without a UA, so we must
    # send a plausible one. Also helps with other endpoints that 4xx
    # unknown clients.
    local user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    # ------------------------------------------------------------------
    # Strategy 1: curl (preferred — works correctly with 204 + SOCKS)
    # ------------------------------------------------------------------
    if command -v curl >/dev/null 2>&1; then
        local curl_args="-s -o /dev/null --max-time ${timeout} --connect-timeout ${timeout} -A '${user_agent}'"
        local curl_code

        if [ -n "$proxy" ]; then
            # curl handles http://, https://, socks5://, socks5h:// natively
            curl_code=$(curl -s -o /dev/null \
                --max-time "$timeout" \
                --connect-timeout "$timeout" \
                -A "$user_agent" \
                -w "%{http_code}" \
                --proxy "$proxy" "$url" 2>/dev/null) || curl_code="000"
        else
            curl_code=$(curl -s -o /dev/null \
                --max-time "$timeout" \
                --connect-timeout "$timeout" \
                -A "$user_agent" \
                -w "%{http_code}" \
                "$url" 2>/dev/null) || curl_code="000"
        fi

        # Treat 2xx and 3xx as success. 3xx is included because Instagram
        # may redirect (e.g. to a login page or regional CDN), and that
        # still proves the proxy chain works.
        case "$curl_code" in
            2[0-9][0-9]|3[0-9][0-9]) return 0 ;;
            *)                        return 1 ;;
        esac
    fi

    # ------------------------------------------------------------------
    # Strategy 2: wget + parse HTTP status from --server-response
    # ------------------------------------------------------------------
    # Both GNU wget and BusyBox wget support -S / --server-response,
    # which prints the HTTP status line to stderr. We grep that line for
    # a 2xx or 3xx status code, ignoring the (potentially bogus) exit
    # code that BusyBox returns for empty-body responses.
    local wget_output

    if [ -n "$proxy" ]; then
        # wget honours http_proxy / https_proxy env vars.
        # NOTE: BusyBox wget does NOT support socks5:// proxy URLs —
        # only http://. If auto-detection picked socks5:// and curl is
        # not available, this probe will fail; that is the user's signal
        # to install curl (opkg install curl).
        wget_output=$(http_proxy="$proxy" https_proxy="$proxy" \
            wget -q -O /dev/null -S --timeout="$timeout" \
            -U "$user_agent" "$url" 2>&1)
    else
        wget_output=$(wget -q -O /dev/null -S --timeout="$timeout" \
            -U "$user_agent" "$url" 2>&1)
    fi

    # Look for the first HTTP status line and extract the code.
    # Format: "  HTTP/1.1 200 OK" (GNU) or "  HTTP/1.1 200" (BusyBox)
    local code
    code=$(echo "$wget_output" | awk '/HTTP\//{print $2; exit}')

    # Treat 2xx and 3xx as success.
    case "$code" in
        2[0-9][0-9]|3[0-9][0-9]) return 0 ;;
        *)                        return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Check whether the current sing-box instance is healthy.
# Performs three sequential checks:
#   1. sing-box process is running
#   2. sing-box config file is syntactically valid (if sing-box binary
#      and config file are available)
#   3. connectivity probe — requests SINGBOX_CHECK_URL (default:
#      https://instagram.com) through the proxy path auto-detected from
#      the sing-box config. Instagram is used because it is NOT directly
#      reachable from Russian/CIS ISPs, so a successful probe proves
#      traffic is really going through the proxy.
#      Proxy auto-detection picks (in priority order):
#        - http/mixed inbound → http://127.0.0.1:<listen_port>
#        - socks inbound      → socks5://127.0.0.1:<listen_port>
#        - tun/tproxy inbound → direct request (transparent mode)
# Returns: 0 if sing-box is considered working, 1 otherwise
# -----------------------------------------------------------------------------
check_singbox_working() {
    echo "=== sing-box health check ==="

    # ------------------------------------------------------------------
    # Step 1: process check
    # ------------------------------------------------------------------
    local sb_pid
    sb_pid=$(pidof sing-box 2>/dev/null)
    if [ -z "$sb_pid" ]; then
        echo "[FAIL] sing-box process is not running"
        return 1
    fi
    echo "[OK]   sing-box process is running (PID: $sb_pid)"

    # ------------------------------------------------------------------
    # Step 2: config validation (only if binary and config are available)
    # ------------------------------------------------------------------
    if [ -n "$SINGBOX_CONFIG_PATH" ] && [ -f "$SINGBOX_CONFIG_PATH" ]; then
        if command -v sing-box >/dev/null 2>&1; then
            if ! sing-box check -c "$SINGBOX_CONFIG_PATH" >/dev/null 2>&1; then
                echo "[FAIL] sing-box config validation failed: $SINGBOX_CONFIG_PATH"
                return 1
            fi
            echo "[OK]   sing-box config is valid: $SINGBOX_CONFIG_PATH"
        else
            echo "[SKIP] sing-box binary not in PATH, skipping config validation"
        fi
    else
        echo "[SKIP] sing-box config file not found ($SINGBOX_CONFIG_PATH), skipping validation"
    fi

    # ------------------------------------------------------------------
    # Step 3: connectivity probe — request SINGBOX_CHECK_URL through the
    #         proxy. Default URL is https://instagram.com, which is NOT
    #         directly reachable from Russian/CIS ISPs, so a successful
    #         response proves traffic is really going through the proxy.
    #         A failed response means the proxy chain is broken and the
    #         script should fetch new subscription links.
    # ------------------------------------------------------------------
    # Determine probe proxy: explicit override first, otherwise auto-detect
    # from the sing-box config file.
    local probe_proxy="$SINGBOX_CHECK_PROXY"

    if [ -z "$probe_proxy" ] && [ -n "$SINGBOX_CONFIG_PATH" ] && [ -f "$SINGBOX_CONFIG_PATH" ]; then
        echo "Auto-detecting probe proxy from $SINGBOX_CONFIG_PATH..."
        probe_proxy=$(detect_singbox_check_proxy)
        if [ $? -ne 0 ]; then
            echo "[WARN] could not auto-detect proxy from config; falling back to direct request"
            probe_proxy=""
        fi
        if [ -z "$probe_proxy" ]; then
            echo "  → direct mode (tun/tproxy inbound or no proxy inbound)"
        else
            echo "  → using proxy: $probe_proxy"
        fi
    elif [ -n "$probe_proxy" ]; then
        echo "Using explicit SINGBOX_CHECK_PROXY: $probe_proxy"
    else
        echo "No config to inspect and no explicit proxy — using direct request"
    fi

    # Retry the probe up to SINGBOX_CHECK_RETRIES times. A single transient
    # failure should not trigger a subscription refresh.
    local probe_ok=0
    local attempt
    for attempt in $(seq 1 "${SINGBOX_CHECK_RETRIES:-1}"); do
        if probe_http "$SINGBOX_CHECK_URL" "$probe_proxy" "$SINGBOX_CHECK_TIMEOUT"; then
            probe_ok=1
            break
        fi
        if [ "$attempt" -lt "${SINGBOX_CHECK_RETRIES:-1}" ]; then
            echo "  probe attempt $attempt/${SINGBOX_CHECK_RETRIES} failed, retrying in 1s..."
            sleep 1
        fi
    done

    if [ $probe_ok -ne 1 ]; then
        echo "[FAIL] connectivity probe to $SINGBOX_CHECK_URL failed"
        echo "       (timeout=${SINGBOX_CHECK_TIMEOUT}s, retries=${SINGBOX_CHECK_RETRIES}, proxy='${probe_proxy:-direct}')"
        echo "       → proxy chain is broken or $SINGBOX_CHECK_URL is unreachable through it"
        return 1
    fi
    echo "[OK]   connectivity probe to $SINGBOX_CHECK_URL succeeded"
    echo "=== sing-box is healthy ==="
    return 0
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
        vtype=$(echo "$query" | sed 's|.*type=\([^&#]*\).*|\1|')
        case "$vtype" in
            tcp|raw|udp|grpc|http|httpupgrade|ws|kcp) ;;
            *)
                echo "Invalid VLESS URL: unsupported type=$vtype" >&2
                return 1
                ;;
        esac
    fi
    
    # Check for supported security parameter
    if echo "$query" | grep -qE 'security='; then
        local security
        security=$(echo "$query" | sed 's|.*security=\([^&#]*\).*|\1|')
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
            insecure=$(echo "$query" | sed 's|.*insecure=\([^&#]*\).*|\1|')
            if [ "$insecure" != "0" ] && [ "$insecure" != "1" ]; then
                echo "Invalid Hysteria2 URL: insecure must be 0 or 1" >&2
                return 1
            fi
        fi
        
        # Check obfs parameter
        if echo "$query" | grep -qE 'obfs='; then
            local obfs
            obfs=$(echo "$query" | sed 's|.*obfs=\([^&#]*\).*|\1|')
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
            -f|--force)
                SKIP_SINGBOX_CHECK=1
                echo "sing-box health check will be skipped (--force)"
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Error: unknown option '$1'"
                echo "Run '$0 --help' for usage"
                exit 1
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

    # Run prerequisite checks (subscription file + podkop urltest mode)
    check_prerequisites

    # ------------------------------------------------------------------
    # Step 0: health-check the current sing-box instance.
    # If it is healthy, there is nothing to do — exit successfully.
    # ------------------------------------------------------------------
    if [ "$SKIP_SINGBOX_CHECK" -eq 1 ]; then
        echo "Skipping sing-box health check (SKIP_SINGBOX_CHECK=1)"
    else
        if check_singbox_working; then
            echo "Current sing-box config is working — no update needed."
            exit 0
        fi
        echo "sing-box is NOT healthy — proceeding with subscription update..."
    fi

    # Run main workflow: download subscription, then update podkop config
    # (update_podkop_config itself skips restart if new links equal current)
    download_subscription
    update_podkop_config

    exit 0
}

# Run main function with all arguments
main "$@"