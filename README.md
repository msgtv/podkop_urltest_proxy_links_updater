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

1. Clone or copy the scripts to your OpenWrt router
2. Create a `sub_link` file containing your subscription URL:
   ```
   https://your-subscription-provider.com/api/subscribe?token=xxx
   ```
3. Run the install script:
   ```sh
   ./install.sh
   ```

### Custom Schedule

The install script accepts cron parameters for custom scheduling:

```sh
./install.sh                    # every 12 hours (default)
./install.sh 0 */6 * * *        # every 6 hours
./install.sh 0 3 * * *          # every day at 3:00
./install.sh 0 0 * * 0          # every Sunday at 00:00
./install.sh 30 */4 * * *       # every 4 hours at :30
```

## Usage

### Manual Execution

```sh
./urltest_proxy_links_updater.sh [subscription_file]
```

- `subscription_file` - Path to file containing subscription URL (default: `sub_link`)

### How It Works

1. Reads subscription URL from the specified file
2. Downloads proxy configurations using `wget`
3. Compares new configuration with current Podkop settings
4. Updates `urltest_proxy_links` in Podkop configuration if changed
5. Restarts Podkop service only when changes are detected

## Files

| File | Description |
|------|-------------|
| `urltest_proxy_links_updater.sh` | Main updater script |
| `install.sh` | Installation script for crontab setup |
| `sub_link` | File containing subscription URL (create this) |

## Configuration

The updater modifies Podkop's UCI configuration:
- Section: `@section[0]`
- Option: `urltest_proxy_links`

## License

MIT License - See project files for details.
