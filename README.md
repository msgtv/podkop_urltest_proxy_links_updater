# Podkop URLTest Proxy Links Updater

Automatic subscription link updater for Podkop on OpenWrt routers. This tool downloads proxy configurations from a subscription URL and updates Podkop's `urltest_proxy_links` setting automatically.

## Features

- **Automatic Updates**: Downloads subscription links and updates Podkop configuration
- **Smart Change Detection**: Only restarts Podkop when configuration actually changes
- **Cron Scheduling**: Configurable automatic execution via crontab
- **OpenWrt Integration**: Designed specifically for OpenWrt with Podkop service

## Requirements

- OpenWrt router with Podkop installed
- `wget` for downloading subscriptions
- `uci` for configuration management
- `crontab` for scheduling (optional)

## Installation

### Quick Start

1. **Create a subscription file** with your proxy subscription URL:
   ```sh
   echo "https://your-subscription-provider.com/api/subscribe?token=xxx" > /root/sub_link
   ```

2. **Download the install script**:
   ```sh
   wget https://raw.githubusercontent.com/msgtv/podkop_urltest_proxy_links_updater/refs/heads/main/install.sh
   ```

3. **Make it executable**:
   ```sh
   chmod a+x ./install.sh
   ```

4. **Run the installer** with your subscription file path:
   ```sh
   ./install.sh /root/sub_link
   ```

### Custom Schedule

The install script accepts cron parameters after the subscription file path:

```sh
./install.sh /root/sub_link                    # every 12 hours (default)
./install.sh /root/sub_link 0 */6 * * *        # every 6 hours
./install.sh /root/sub_link 0 3 * * *          # every day at 3:00
./install.sh /root/sub_link 0 0 * * 0          # every Sunday at 00:00
./install.sh /root/sub_link 30 */4 * * *       # every 4 hours at :30
```

## Usage

### Manual Execution

```sh
./urltest_proxy_links_updater.sh [subscription_file]
```

- `subscription_file` - Path to file containing subscription URL (default: `sub_link`)

### Prerequisites

Before running the script, ensure Podkop is configured in **urltest mode**:

```sh
uci set podkop.@section[0].proxy_config_type='urltest'
uci commit podkop
```

The script will exit with an error if `proxy_config_type` is not set to `urltest`.

### How It Works

1. Validates that Podkop is configured in `urltest` mode (`proxy_config_type`)
2. Reads subscription URL from the specified file
3. Downloads proxy configurations using `wget`
4. Compares new configuration with current Podkop settings
5. Updates `urltest_proxy_links` in Podkop configuration if changed
6. Restarts Podkop service only when changes are detected

## Files

| File | Description |
|------|-------------|
| `urltest_proxy_links_updater.sh` | Main updater script (downloaded automatically) |
| `install.sh` | Installation script for crontab setup |
| `sub_link` | File containing subscription URL (create this) |

## Installation Details

The `install.sh` script performs the following actions:

1. Copies your subscription file to `/etc/podkop_urltest_proxy_links_updater/sub_link`
2. Downloads the latest `urltest_proxy_links_updater.sh` from GitHub to `/opt/podkop_urltest_proxy_links_updater/`
3. Adds a cron job for automatic updates
4. The updater script runs on schedule and updates Podkop configuration when subscription changes

## Configuration

The updater modifies Podkop's UCI configuration:
- Section: `@section[0]`
- Option: `urltest_proxy_links`

### Required Podkop Settings

The script requires the following Podkop configuration:

| Option | Required Value | Description |
|--------|----------------|-------------|
| `proxy_config_type` | `urltest` | Must be set to `urltest` mode |
| `urltest_proxy_links` | *auto-populated* | Proxy URLs for testing (updated by this script) |

To check your current configuration:
```sh
uci get podkop.@section[0].proxy_config_type
```

## License

MIT License - See project files for details.
