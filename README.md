# Podkop URLTest Proxy Links Updater

Automatic subscription link updater for [Podkop](https://github.com/yurbons/podkop) on OpenWrt routers.

The tool **only refreshes the subscription when sing-box is actually broken**. Before downloading anything, the updater runs a three-stage health check against the running sing-box instance; if everything works, it exits immediately without touching the network or Podkop configuration. If sing-box is down or misbehaving, the updater fetches the latest subscription, validates every link, compares with the current Podkop settings, and applies changes only when they actually differ.

## Features

- **Sing-box health check before any download** — process up, config valid, connectivity probe through the actual proxy path
- **Auto-detection of probe path** — reads `/etc/sing-box/config.json` and picks `mixed`/`http` → `socks` → `tun`/`tproxy` (direct), no manual configuration needed
- **Smart change detection** — Podkop is restarted only when the new link set actually differs from the current one
- **Per-link validation** — `ss://`, `vless://`, `trojan://`, `socks4/4a/5://`, `hysteria2://`/`hy2://` are syntax-checked before they ever reach Podkop
- **Name-based filtering** — configs whose name contains `LTE` (case-insensitive) are filtered out; pattern is configurable
- **Cron scheduling** — installer sets up `crond` and adds a job with configurable schedule
- **Structured logging** — every cron run appends to `/var/log/podkop_urltest_updater.log` (OpenWrt has no MTA by default)
- **OpenWrt-native** — uses `uci`, `wget`, `jshn` (libubox), `/etc/init.d/podkop`, `pidof`

## Requirements

| Component | Why | Notes |
|---|---|---|
| OpenWrt with Podkop installed | The thing being updated | `podkop` package |
| Podkop in `urltest` mode | The script writes `urltest_proxy_links` | see [Prerequisites](#prerequisites) |
| `sing-box` | Health check + config validation | `sing-box check -c ...` is used when binary is in PATH |
| `wget` (BusyBox) | Subscription download + connectivity probe | shipped with OpenWrt base |
| `uci` | Reading/writing Podkop config | shipped with OpenWrt base |
| `jshn` (libubox) | Parsing `/etc/sing-box/config.json` for probe auto-detection | shipped with OpenWrt base |
| `pidof` | Detecting the sing-box process | shipped with BusyBox |
| `crond` | Scheduled runs | `opkg install cron` if missing |

## Installation

### Quick Start

1. **Create a subscription file** containing the subscription URL:
   ```sh
   echo "https://your-provider.com/api/subscribe?token=xxx" > /root/sub_link
   ```

2. **Download the install script**:
   ```sh
   wget -O /tmp/install.sh \
     https://raw.githubusercontent.com/msgtv/podkop_urltest_proxy_links_updater/refs/heads/main/install.sh
   ```

3. **Make it executable**:
   ```sh
   chmod a+x /tmp/install.sh
   ```

4. **Run the installer** (as root) with your subscription file path:
   ```sh
   /tmp/install.sh /root/sub_link
   ```

The installer will:
- copy your subscription file to `/etc/podkop_urltest_proxy_links_updater/sub_link`
- download the latest `urltest_proxy_links_updater.sh` to `/opt/podkop_urltest_proxy_links_updater/`
- enable and restart `crond`
- add a cron job (output → `/var/log/podkop_urltest_updater.log`)
- run the updater immediately, so you don't have to wait for the first scheduled run

### Custom Schedule

Pass cron fields after the subscription file path:

```sh
./install.sh /root/sub_link                    # every 15 minutes (default)
./install.sh /root/sub_link 0 */6 * * *        # every 6 hours
./install.sh /root/sub_link 0 3 * * *          # every day at 3:00
./install.sh /root/sub_link 0 0 * * 0          # every Sunday at 00:00
./install.sh /root/sub_link 30 */4 * * *       # every 4 hours at :30
./install.sh /root/sub_link 0 2,14 * * *       # at 2:00 and 14:00 every day
```

Cron fields are validated — anything other than digits, `*`, `/`, `,`, `-` is rejected with an error.

### Re-running the Installer

The installer is idempotent. Re-running it with new arguments replaces the previous cron job (matched by script path) instead of adding a duplicate.

## Prerequisites

Before installing or running the updater, Podkop must be in **urltest mode**:

```sh
uci set podkop.@section[0].proxy_config_type='urltest'
uci commit podkop
```

Verify:
```sh
uci get podkop.@section[0].proxy_config_type
# expected: urltest
```

If Podkop is not in urltest mode, both the installer (with a warning) and the updater (with a hard error) will refuse to proceed.

## Usage

### Manual Execution

```sh
/opt/podkop_urltest_proxy_links_updater/urltest_proxy_links_updater.sh [options] [subscription_file]
```

| Argument | Default | Description |
|---|---|---|
| `subscription_file` | `sub_link` (relative to CWD) | Path to file containing subscription URL |
| `-h`, `--help` | — | Show help and exit |
| `-f`, `--force` | — | Skip the sing-box health check; always download + apply |

If no `subscription_file` is passed, the script uses `sub_link` in the current directory. The cron job always calls the script with the absolute path `/etc/podkop_urltest_proxy_links_updater/sub_link`.

### Forcing a Refresh

By default, if sing-box is healthy the script exits immediately. To force a re-download (for example after rotating subscription credentials), use:

```sh
/opt/podkop_urltest_proxy_links_updater/urltest_proxy_links_updater.sh \
  --force \
  /etc/podkop_urltest_proxy_links_updater/sub_link
```

### Exit Codes

| Code | Meaning |
|---|---|
| `0` | Success — either sing-box was healthy and nothing was done, or new links were downloaded and applied (or skipped because identical) |
| `1` | Failure — missing prerequisites, download failed, all links invalid, or uci batch failed |

## How It Works

### High-Level Flow

```
  ┌──────────────────────────┐
  │  check_prerequisites()   │  - sub_link file exists
  │                          │  - podkop proxy_config_type == 'urltest'
  └──────────┬───────────────┘
             │
             ▼
  ┌──────────────────────────┐
  │  check_singbox_working() │  (skipped if --force)
  │  ─ pidof sing-box        │
  │  ─ sing-box check -c ... │
  │  ─ wget probe via proxy  │
  └──────────┬───────────────┘
             │
        ┌────┴────┐
        │         │
     healthy   broken
        │         │
        ▼         ▼
     exit 0   download_subscription()
                    │
                    ▼
              filter_valid_links()
                    │
                    ▼
              update_podkop_config()
                    │
                ┌───┴───┐
                │       │
            changed   identical
                │       │
                ▼       ▼
            restart  exit 0
            podkop   (no restart)
```

### Health Check Stages

`check_singbox_working()` performs three sequential checks. The first failure aborts the health check (and triggers subscription update).

1. **Process check** — `pidof sing-box` must return a non-empty PID. If sing-box is not running, there is nothing to verify.

2. **Config validation** — if the `sing-box` binary is in PATH and the config file at `SINGBOX_CONFIG_PATH` exists, runs `sing-box check -c <config>`. A syntactically invalid config means the running instance is on borrowed time; treat as broken.

3. **Connectivity probe** — performs an HTTP request to `SINGBOX_CHECK_URL` (default: `https://www.gstatic.com/generate_204`) with timeout `SINGBOX_CHECK_TIMEOUT` (default: 10 s). The request goes either:
   - **directly** (when the config has a `tun` or `tproxy` inbound — transparent interception handles routing), or
   - **through an explicit proxy** (when the config has `http`, `mixed`, or `socks` inbounds — `http_proxy` / `https_proxy` env vars are exported for the `wget` call).

The probe proxy is **auto-detected** by parsing `/etc/sing-box/config.json` via `jshn`. Detection priority (most reliable first):

| Inbound type | Probe mode |
|---|---|
| `mixed` / `http` | `http://<listen>:<listen_port>` |
| `socks` | `socks5://<listen>:<listen_port>` |
| `tun` / `tproxy` | direct (kernel-level routing) |

Listen address `0.0.0.0` / `::` is normalized to `127.0.0.1`. IPv6 addresses are bracketed for use in URLs.

### Subscription Processing

When the health check fails (or `--force` is used):

1. The subscription URL is read from the subscription file.
2. The URL is downloaded with `wget`, sending the following headers:
   - `X-HWID` — base64 of `MAC_of_br-lan + "_" + device_model`
   - `X-Device-OS` — from `/etc/os-release` (`$NAME`)
   - `X-Ver-OS` — from `/etc/os-release` (`$VERSION_ID`)
   - `X-Device-Model` — from `/tmp/sysinfo/model`
   - `X-App-Version: 1.0`
3. If the response is base64-encoded (no `://` or `@` characters, valid base64 alphabet), it is decoded.
4. Each line is validated against protocol-specific rules (`ss://`, `vless://`, `trojan://`, `socks4/4a/5://`, `hysteria2://`/`hy2://`). Invalid lines and comments are dropped. Lines whose `#name` part matches `FILTER_NAME_PATTERN` (default: `LTE`, case-insensitive) are also dropped.
5. The valid links are compared (sorted, pipe-separated) against the current `uci get podkop.@section[0].urltest_proxy_links`. If identical, the script exits with `0` and Podkop is **not** restarted.
6. If different, the script builds a `uci batch` that first `set`s the first link, then `add_list`s the rest, then `commit podkop`. On success, `/etc/init.d/podkop restart` is invoked.

## Configuration

### Updater Script (top of `urltest_proxy_links_updater.sh`)

| Variable | Default | Description |
|---|---|---|
| `SUB_FILE` | `sub_link` | Default subscription file path (overridden by CLI argument) |
| `FILTER_NAME_PATTERN` | `LTE` | Case-insensitive substring to filter configs by name |
| `SINGBOX_CONFIG_PATH` | `/etc/sing-box/config.json` | Path to sing-box config; used for validation + probe auto-detection. Set to empty string to skip config validation. |
| `SINGBOX_CHECK_URL` | `https://www.gstatic.com/generate_204` | URL hit by the connectivity probe. Should return 2xx. |
| `SINGBOX_CHECK_TIMEOUT` | `10` | Probe timeout in seconds |
| `SINGBOX_CHECK_PROXY` | `""` (auto-detect) | Explicit probe proxy override, e.g. `http://127.0.0.1:1087` or `socks5://127.0.0.1:1080`. When empty, the value is auto-detected from `SINGBOX_CONFIG_PATH`. |
| `SKIP_SINGBOX_CHECK` | `0` | Set to `1` to skip the health check (equivalent to `--force`) |

### Podkop UCI Configuration

The updater reads and writes the following Podkop options:

| Option | Direction | Description |
|---|---|---|
| `podkop.@section[0].proxy_config_type` | read | Must equal `urltest` |
| `podkop.@section[0].urltest_proxy_links` | read + write | List of proxy URLs; replaced atomically via `uci batch` |

Verify the current value:
```sh
uci get podkop.@section[0].urltest_proxy_links
```

## Files

| Path | Created by | Description |
|---|---|---|
| `/opt/podkop_urltest_proxy_links_updater/urltest_proxy_links_updater.sh` | installer | Main updater script (downloaded from GitHub) |
| `/etc/podkop_urltest_proxy_links_updater/sub_link` | installer | Stable copy of your subscription file |
| `/var/log/podkop_urltest_updater.log` | cron job | Append-only log of cron runs |
| `/etc/sing-box/config.json` | Podkop | sing-box config, read by the updater for health check + probe auto-detection |
| `/tmp/sub_raw.txt` | updater | Temporary: raw downloaded subscription |
| `/tmp/sub_valid.txt` | updater | Temporary: validated links only |

## Logs and Debugging

### Where logs go

- **Interactive runs**: stdout/stderr of the updater script — you see everything in your terminal.
- **Cron runs**: appended to `/var/log/podkop_urltest_updater.log` (redirect set up by the installer).

### Reading the cron log

```sh
tail -f /var/log/podkop_urltest_updater.log
```

### Typical healthy-run output

```
Using file from argument: /etc/podkop_urltest_proxy_links_updater/sub_link
=== sing-box health check ===
[OK]   sing-box process is running (PID: 29910)
[OK]   sing-box config is valid: /etc/sing-box/config.json
Auto-detecting probe proxy from /etc/sing-box/config.json...
  → using proxy: http://127.0.0.1:4534
[OK]   connectivity probe to https://www.gstatic.com/generate_204 succeeded
=== sing-box is healthy ===
Current sing-box config is working — no update needed.
```

### Typical broken-sing-box run (triggers an update)

```
=== sing-box health check ===
[OK]   sing-box process is running (PID: 29910)
[OK]   sing-box config is valid: /etc/sing-box/config.json
Auto-detecting probe proxy from /etc/sing-box/config.json...
  → using proxy: http://127.0.0.1:4534
[FAIL] connectivity probe to https://www.gstatic.com/generate_204 failed
       (timeout=10s, proxy='http://127.0.0.1:4534')
sing-box is NOT healthy — proceeding with subscription update...
Requesting https://your-provider.com/api/subscribe?token=xxx
Found 12 configs
Validating proxy URLs...
[STATS] Total: 12, Valid: 10, Filtered: 1, Invalid: 1
Valid links after filtering: 10
Found 10 links to configure
Changes detected — updating podkop configuration...
Podkop configuration updated successfully
```

### Forcing a refresh for debugging

```sh
/opt/podkop_urltest_proxy_links_updater/urltest_proxy_links_updater.sh \
  --force \
  /etc/podkop_urltest_proxy_links_updater/sub_link
```

## Uninstall

Remove the cron job, the script, and the subscription file:

```sh
# Remove the cron job (matched by script path)
crontab -l 2>/dev/null | grep -vF /opt/podkop_urltest_proxy_links_updater/urltest_proxy_links_updater.sh | crontab -

# Remove installed files
rm -rf /opt/podkop_urltest_proxy_links_updater
rm -rf /etc/podkop_urltest_proxy_links_updater
rm -f /var/log/podkop_urltest_updater.log
```

Podkop itself is not affected; its `urltest_proxy_links` value stays at whatever was last applied.

## FAQ

### The cron log shows `[FAIL] connectivity probe ... failed`, but the internet works fine

The probe runs through the sing-box proxy path, not directly. If sing-box is up but the configured upstream is dead, the probe correctly fails. The script will then try to refresh the subscription. If the subscription server is also unreachable (because the proxy chain is broken), the script will exit with code 1 — this is expected; cron will retry on the next scheduled run.

### I want to use a different probe URL

Edit `SINGBOX_CHECK_URL` at the top of `/opt/podkop_urltest_proxy_links_updater/urltest_proxy_links_updater.sh`. A good choice is any URL that returns HTTP 204 with a small body, e.g. `https://cp.cloudflare.com/generate_204`.

### I want to disable the health check entirely

Either pass `--force` on the command line, or set `SKIP_SINGBOX_CHECK=1` at the top of the script. Note that this means the subscription is downloaded on every run, even when nothing is wrong.

### My sing-box config is not at `/etc/sing-box/config.json`

Set `SINGBOX_CONFIG_PATH` at the top of the script to the actual path. If you don't know the path, check `/etc/init.d/podkop` — it usually contains the `-c` argument passed to `sing-box`.

### I want to use an explicit proxy for the probe instead of auto-detection

Set `SINGBOX_CHECK_PROXY` to a non-empty value (e.g. `socks5://127.0.0.1:1080`). Auto-detection is skipped when this variable is set.

## License

MIT License — see project files for details.