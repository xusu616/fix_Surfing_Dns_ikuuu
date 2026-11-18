# fix_Surfing_Dns_ikuuu

A lightweight root module for **Magisk / KernelSU / APatch** that extracts the upstream DNS resolver declared in local Surfing subscription profiles into `config.yaml`'s `proxy-server-nameserver`, with precision block backup, automatic validation & rollback, and real-time restore on disable or uninstall.

## Features

- **Automatic Extraction & IP Resolution (with Fallback)**
  - Scans `/data/adb/box_bll/clash/proxies/*.yaml` (and `*.yml`) under `dns.nameserver-policy` for `tcp://` resolver entries.
  - Resolves hostnames to public IPv4 via public DNS (`223.5.5.5` / `119.29.29.29`, bypassing local UID/GID DNS redirects when available, with DoH JSON fallback), falling back cleanly to the raw hostname if resolution is unavailable.
- **Precision Block Editing & Validation**
  - Uses line-bounded `awk`/`sed` editing to update only `dns.proxy-server-nameserver` (and optionally append `,no-resolve` to active `RULE-SET,CN_IP` rules).
  - Validates structure and runs `clash -t` plus a live resolution check (when online) immediately after editing; automatically rolls back to the pre-edit backup on any failure.
- **AdGuardHome Coexistence**
  - Leaves `nameserver-policy`, `nameserver`, and `direct-nameserver` untouched so existing or future `127.0.0.1:<port>` local DNS bindings remain intact.
- **Incremental Restore on Disable / Uninstall**
  - Captures exact original modified blocks under `/data/adb/fix_Surfing_Dns_ikuuu/backup/` instead of blindly overwriting unrelated user changes on rollback.
  - Runs BusyBox `inotifyd` via `service.sh` to watch `disable` and `remove` events and restore/re-apply immediately when toggled in the root manager.
- **Action Button Diagnostics**
  - Includes `action.sh` (inspired by [ikuuudnstester](https://github.com/xusu616/ikuuudnstester)) to inspect active configuration, verify subscription consistency (auto-repairing drift when enabled), check AGH compatibility, probe DNS resolution, validate with `clash -t`, and test controller delay.
  - Works directly via the manager Action button on **KernelSU v1.0+ / APatch / Magisk v27+**; on older managers without an Action button (e.g., KernelSU v0.9.5), run `su -c 'sh /data/adb/modules/fix_Surfing_Dns_ikuuu/action.sh'`.

## Interactive Installer Options

During installation, use **Volume Up** / **Volume Down** (10s timeout auto-selects default):

1. **DNS Format**: `[Vol+]` Resolve to public IPv4 with domain fallback (default) | `[Vol-]` Keep raw subscription domain
2. **Existing `proxy-server-nameserver`**: `[Vol+]` Replace with extracted DNS (default) | `[Vol-]` Prepend above existing entries
3. **`CN_IP` Optimization**: `[Vol+]` Append `,no-resolve` to `RULE-SET,CN_IP` (default) | `[Vol-]` Leave `CN_IP` rule unchanged
4. **Sync Mode**: `[Vol+]` Apply on install + manual `Action` button check/repair (default) | `[Vol-]` Also auto-sync on boot if config/subscription changes

## Requirements

- Rooted Android with **Magisk (v20.4+)**, **KernelSU**, or **APatch**
- Installed **Surfing** module (`/data/adb/box_bll/clash/config.yaml` and subscription YAML files under `/data/adb/box_bll/clash/proxies/`)

## Author & License

- Author: `suxv616`
- License: MIT ([LICENSE](LICENSE))
