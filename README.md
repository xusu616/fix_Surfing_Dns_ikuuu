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
- **Optional AGH DNSPod Routing Fix**
  - For the verified AGH + Surfing layout, changes AGH from `root:net_admin` to `root:inet` and gives `1.12.12.12/32` and `120.53.53.53/32` priority routes through the existing `DNS连接` group.
  - Checks the real core identity, transparent capture rules, Rule mode and selected proxy before switching AGH. Requires IP-based DNS-over-HTTPS upstreams and an independent public-IP node resolver to avoid bootstrap loops.
  - Does not change AGH upstream providers, filtering, or local DNS bindings. Already-correct manual configuration is not claimed as module-owned.
  - New staged installs/upgrades defer this feature until reboot, so the matching restore code is active before AGH is changed.
- **Incremental Restore on Disable / Uninstall**
  - Captures exact original modified blocks under `/data/adb/fix_Surfing_Dns_ikuuu/backup/` instead of blindly overwriting unrelated user changes on rollback.
  - Runs BusyBox `inotifyd` via `service.sh` to watch `disable` and `remove` events and restore/re-apply immediately when toggled in the root manager.
  - Stores only the original `adg_group` assignment and module-added, marked routing lines. Keeps later unrelated user edits; conflicting edits and failed reloads retain recovery data.
- **Action Button Diagnostics**
  - Includes `action.sh` (inspired by [ikuuudnstester](https://github.com/xusu616/ikuuudnstester)) to inspect active configuration, verify subscription consistency (auto-repairing drift when enabled), check AGH compatibility, probe DNS resolution, validate with `clash -t`, and test controller delay.
  - Works directly via the manager Action button on **KernelSU v1.0+ / APatch / Magisk v27+**; on older managers without an Action button (e.g., KernelSU v0.9.5), run `su -c 'sh /data/adb/modules/fix_Surfing_Dns_ikuuu/action.sh'`.

## Interactive Installer Options

During installation, use **Volume Up** / **Volume Down** (10s timeout auto-selects default):

1. **DNS Format**: `[Vol+]` Resolve to public IPv4 with domain fallback (default) | `[Vol-]` Keep raw subscription domain
2. **Existing `proxy-server-nameserver`**: `[Vol+]` Replace with extracted DNS (default) | `[Vol-]` Prepend above existing entries
3. **`CN_IP` Optimization**: `[Vol+]` Append `,no-resolve` to `RULE-SET,CN_IP` (default) | `[Vol-]` Leave `CN_IP` rule unchanged
4. **Sync Mode**: `[Vol+]` Apply on install + manual `Action` button check/repair (default) | `[Vol-]` Also auto-sync on boot if config/subscription changes
5. **AGH Routing Fix**: `[Vol+]` Enable compatible AGH DNSPod proxy routing after reboot (default) | `[Vol-]` Disable and restore only AGH changes owned by this module

AGH coordination runs on boot independently of subscription auto-sync. When changing option 5 on a staged upgrade, reboot to activate the new setting and restore code.

Once a boot DNS transaction has been attempted, the same boot does not immediately run a second AGH repair after success or failure. Failed transactions keep recovery data for the next manual check or boot.

## AGH 联动修复说明

此功能解决已经验证的这条路径问题：AGH 的 `root:net_admin` 身份被 Surfing 豁免，DNSPod DoH 在 Wi-Fi 下直连超时，而经代理可以访问。

- `proxy-server-nameserver` 继续只负责 ikuuu 节点入口解析；普通 DNS 仍交给 AGH，广告过滤保留。
- AGH 必须使用 `root`、关闭自身 `enable_iptables`，并采用 IP 格式的 HTTPS 上游；主上游至少包含 `1.12.12.12` 或 `120.53.53.53`。域名上游、自定义上游文件或客户端专用上游等未验证布局会明确跳过。
- `DNS连接` 必须选中可用代理。AGH 改为 `inet` 后，其他出站连接也会接受 Surfing 分流。
- 首次安装后重启；如果启动时 Surfing 尚未就绪，保留原 AGH 配置并记录等待状态，可在两项服务正常运行后点模块「操作」检查/应用。
- 如果手机已经手动配置为 `inet` 且两条规则已在最前面，模块不会重复插入，也不会在禁用/卸载时删除这份手动配置。
- 恢复资料位于 `/data/adb/fix_Surfing_Dns_ikuuu/backup/`；恢复失败时不要删除该目录。「操作」会检查真实进程 UID/GID、端口和推特 API/图片/视频域名的 DNS 响应，缓存命中或 DNS 返回成功不代表完整应用加载测试通过。

## Development checks

```sh
sh tests/test_agh_fix.sh
sh tests/test_agh_lifecycle.sh
sh tests/test_module_integration.sh
sh tests/test_boot_coordination.sh
```

The lifecycle suite uses isolated fixtures and mocked service/kernel I/O. It never modifies a phone or live root-manager configuration.

## Requirements

- Rooted Android with **Magisk (v20.4+)**, **KernelSU**, or **APatch**
- Installed **Surfing** module (`/data/adb/box_bll/clash/config.yaml` and subscription YAML files under `/data/adb/box_bll/clash/proxies/`)

## Author & License

- Author: `suxv616`
- License: MIT ([LICENSE](LICENSE))
