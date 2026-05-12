# luci-app-parentalcontrol

Time-based parental control for OpenWrt with per-device scheduling, temporary overrides, and a LuCI web interface.

## Features

- **Per-device access control** — block internet access for specific devices by MAC address on a schedule
- **Flexible scheduling** — define block windows per day-of-week with start/end times (e.g., Mon-Fri 22:00-07:00)
- **Temporary overrides** — pause blocking for 30 min, 1 hour, or 2 hours, with cancel/resume support
- **Global enable/disable** — one-click toggle to suspend all parental controls
- **Per-rule enable/disable** — checkbox per device to quickly toggle individual rules
- **Multiple schedules per rule** — add weekday and weekend schedules on a single device rule
- **Edit rules** — modal dialog for editing device name and schedules
- **Device picker** — auto-populated dropdown from DHCP leases and ARP table
- **Modal dialogs** — add and edit forms open in clean popup modals
- **Compact day display** — shows "Mon-Fri" instead of listing each day, auto-detects ranges
- **Rule reordering** — drag-and-drop rows or use ▲/▼ arrow buttons to control priority
- **Toast notifications** — actions update the UI in-place with brief status toasts, no page reloads
- **Blocked traffic stats** — live packet and byte counters per rule from nftables, auto-refreshing
- **nftables-based** — uses the `meta hour` and `meta day` matchers in the forward chain for efficient kernel-level blocking

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    LuCI Browser UI                      │
│              (settings.js — JS client view)             │
└────────────────────────┬────────────────────────────────┘
                         │ ubus RPC
┌────────────────────────▼────────────────────────────────┐
│                   rpcd plugin                           │
│            (/usr/libexec/rpcd/parentalcontrol)           │
│                                                         │
│  Methods: get_status, list_devices, toggle_global,      │
│           toggle_rule, set_override, cancel_override,   │
│           add_rule, update_rule, delete_rule             │
└────────────────────────┬────────────────────────────────┘
                         │ reads/writes UCI, calls backend
┌────────────────────────▼────────────────────────────────┐
│              UCI Config + Backend Script                 │
│                                                         │
│  /etc/config/parentalcontrol     — persistent config    │
│  /usr/libexec/parentalcontrol.sh — nftables generator   │
│  /tmp/parentalcontrol.nft — generated     │
└────────────────────────┬────────────────────────────────┘
                         │ nft -f
┌────────────────────────▼────────────────────────────────┐
│                  nftables (kernel)                       │
│                                                         │
│  table inet parentalcontrol {                           │
│    chain forward {                                      │
│      type filter hook forward priority -1; policy accept│
│      meta day {Mon,Tue,...} ether saddr XX:XX:XX:XX:XX  │
│        meta hour "22:00"-"23:59:59" counter drop        │
│      meta day {Mon,Tue,...} ether saddr XX:XX:XX:XX:XX  │
│        meta hour "00:00"-"07:00" counter drop           │
│    }                                                    │
│  }                                                      │
└─────────────────────────────────────────────────────────┘
```

## File Structure

```
luci-app-parentalcontrol/
├── Makefile                                          # OpenWrt package build definition
├── build-apk.sh                                      # APK package builder (note: OpenWrt 25.x
│                                                     #   uses ADB binary format, not yet supported)
├── htdocs/luci-static/resources/view/parentalcontrol/
│   └── settings.js                                   # LuCI JavaScript frontend view
└── root/
    ├── etc/
    │   ├── config/parentalcontrol                    # UCI config — default (global enabled)
    │   ├── init.d/parentalcontrol                    # procd init script
    │   └── uci-defaults/luci-app-parentalcontrol     # first-boot setup
    └── usr/
        ├── libexec/
        │   ├── parentalcontrol.sh                    # backend: reads UCI, generates nftables
        │   └── rpcd/parentalcontrol                  # rpcd shell plugin: API for LuCI
        └── share/
            ├── luci/menu.d/luci-app-parentalcontrol.json    # LuCI menu entry
            └── rpcd/acl.d/luci-app-parentalcontrol.json     # RPC access control
```

## UCI Config Schema

```
# /etc/config/parentalcontrol

config global 'global'
    option enabled '1'                    # Global kill switch (0 = all rules suspended)

config rule
    option name 'Kids iPad'              # Human-readable device name
    option mac 'AA:BB:CC:DD:EE:FF'       # Device MAC address
    option enabled '1'                    # Per-rule enable/disable
    option override_until '0'            # Epoch timestamp for temp override (0 = none)
    list schedule 'mon,tue,wed,thu,fri 22:00-07:00'   # Blocked time windows
    list schedule 'sat,sun 23:00-08:00'               # Multiple schedules supported
```

## How It Works

### Blocking

The backend script (`parentalcontrol.sh apply`) reads the UCI config and generates an nftables include
file at `/tmp/parentalcontrol.nft`. Each enabled rule becomes one or more nftables rules
that match on:

- `ether saddr` — the device's MAC address
- `meta day` — day-of-week filter (Monday, Tuesday, etc.)
- `meta hour` — time-of-day range in **local time** (no conversion needed)

Traffic matching these rules is dropped with a counter for visibility.

### Timezone Handling

On OpenWrt, nftables `meta hour` uses the system's **local time**, not UTC. Schedule times from the
UCI config are used directly — no timezone conversion is performed.

When a schedule crosses midnight (e.g., 22:00-07:00), it's split into two rules:
- `"22:00"-"23:59:59"` (covers up to end of day)
- `"00:00"-"07:00"` (covers start of next day)

### Temporary Overrides

Overrides use epoch timestamps, making them timezone-agnostic. When a user pauses a rule for N minutes:

1. `override_until` is set to `now + N*60` (epoch seconds)
2. `parentalcontrol.sh apply` sees the active override and skips generating nftables rules for that device
3. A cron job runs every minute (`parentalcontrol.sh check_overrides`) to check for expired overrides
4. When an override expires, `override_until` is reset to `0` and rules are regenerated

Users can cancel an override early via the "Resume" button, which sets `override_until` to `0` and
reapplies rules immediately.

### Status Detection

The `get_status` rpcd method computes each rule's real-time status by checking the current day and
time against the rule's schedules:

- **Blocked** — rule is enabled, global is enabled, and current time falls within a schedule window
- **Scheduled** — rule is enabled but current time is outside all schedule windows
- **Paused** — temporary override is active (regardless of schedule)
- **Inactive** — rule is disabled or global parental control is off

For schedules that cross midnight (e.g., "fri 22:00-07:00"), the status check correctly matches the
post-midnight portion against the previous day's schedule.

### rpcd API

The rpcd plugin (`/usr/libexec/rpcd/parentalcontrol`) exposes these ubus methods:

| Method | Params | Description |
|--------|--------|-------------|
| `get_status` | — | Returns global state, rules with status, and live nftables counters |
| `list_devices` | — | Returns devices from DHCP leases + ARP table |
| `toggle_global` | `enabled` | Enable/disable all parental controls |
| `toggle_rule` | `section`, `enabled` | Enable/disable a specific rule |
| `set_override` | `section`, `minutes` | Temporarily pause a rule |
| `cancel_override` | `section` | Cancel an active override |
| `add_rule` | `name`, `mac`, `schedules`, `enabled` | Create a new rule |
| `update_rule` | `section`, `name`, `schedules`, `enabled` | Modify an existing rule |
| `move_rule` | `section`, `direction` | Move a rule one position (`direction`: "up" or "down") |
| `reorder_rule` | `section`, `position` | Move a rule to a specific 0-based position (used by drag-and-drop) |
| `delete_rule` | `section` | Remove a rule |

Schedules are passed as pipe-separated strings: `"mon,tue,wed 22:00-07:00|sat,sun 23:00-08:00"`

### LuCI Frontend

The UI is a single JavaScript view (`settings.js`) using LuCI's client-side framework. It communicates
exclusively via ubus RPC calls — no direct UCI manipulation from the browser. The view auto-refreshes
status badges every 30 seconds via LuCI's `poll` module.

**Table columns:**
- **Reorder** — drag handle (⠿) for drag-and-drop (desktop + touch), plus ▲/▼ buttons as fallback
- **Device** — name + MAC address
- **Schedule** — each schedule on its own line, with compact day ranges (e.g., "Mon-Fri 22:00-07:00")
- **Status** — Blocked (red), Scheduled (blue), Paused (orange), or Inactive (gray) badge
- **Blocked** — live packet count and byte total from nftables counters (auto-refreshes)
- **Enabled** — checkbox toggle per rule
- **Override** — pause duration dropdown (when blocked) or "Paused Xm" + Resume button (when paused)
- **Actions** — Edit (opens modal) and Delete

All actions update the table in-place with toast notifications — no full page reloads.

**Add/Edit modals:**
- Blocking modal dialog — prevents background scrolling on both desktop and mobile
- Inherits LuCI theme background color
- Day-of-week toggle buttons (highlight blue when active)
- Multiple schedule blocks with "Schedule 1", "Schedule 2" headers
- "+ Add Schedule" to add more blocks, "Remove" to delete a block
- Device picker dropdown with manual MAC entry fallback (add only)
- Auto-fills device name from hostname when selecting a device from dropdown
- Inline validation errors displayed inside the modal (not on the main page)
- Responsive layout — form elements stack vertically on mobile

**Responsive design:**
- Uses LuCI's div-based table system (`.table`, `.tr`, `.td` classes with `data-title` attributes)
- On mobile (`max-device-width: 600px`), table rows convert to card layout automatically via the
  LuCI bootstrap theme
- Touch drag-and-drop on mobile via the grip handle (`touchstart`/`touchmove`/`touchend`)
- Modal, forms, and action buttons adapt to narrow screens

## Installation (Direct Copy)

Since OpenWrt 25.x uses APK v3 (ADB binary format) which cannot be easily built without the SDK,
install by copying files directly:

```bash
# From your development machine (first-time install):
cd luci-app-parentalcontrol
scp -r root/* root@<router-ip>:/
scp -r htdocs/luci-static/resources/view/parentalcontrol root@<router-ip>:/www/luci-static/resources/view/

# On the router:
chmod +x /usr/libexec/parentalcontrol.sh /usr/libexec/rpcd/parentalcontrol /etc/init.d/parentalcontrol
sh /etc/uci-defaults/luci-app-parentalcontrol
/etc/init.d/parentalcontrol start
```

The menu entry appears at **Services > Parental Control** in LuCI.

## Updating

**IMPORTANT:** Do NOT use `scp -r root/* root@<router-ip>:/` for updates — it overwrites
`/etc/config/parentalcontrol` and erases your rules. Copy only the changed files:

```bash
# Update scripts and UI (does NOT touch config):
scp root/usr/libexec/parentalcontrol.sh root@<router-ip>:/usr/libexec/parentalcontrol.sh
scp root/usr/libexec/rpcd/parentalcontrol root@<router-ip>:/usr/libexec/rpcd/parentalcontrol
scp htdocs/luci-static/resources/view/parentalcontrol/settings.js root@<router-ip>:/www/luci-static/resources/view/parentalcontrol/settings.js

# On the router:
chmod +x /usr/libexec/parentalcontrol.sh /usr/libexec/rpcd/parentalcontrol
/etc/init.d/rpcd restart
/etc/init.d/parentalcontrol restart
```

## Uninstall

```bash
/etc/init.d/parentalcontrol stop
/etc/init.d/parentalcontrol disable
rm -f /usr/libexec/parentalcontrol.sh
rm -f /usr/libexec/rpcd/parentalcontrol
rm -f /etc/init.d/parentalcontrol
rm -f /etc/config/parentalcontrol
rm -f /tmp/parentalcontrol.nft
rm -f /usr/share/luci/menu.d/luci-app-parentalcontrol.json
rm -f /usr/share/rpcd/acl.d/luci-app-parentalcontrol.json
rm -rf /www/luci-static/resources/view/parentalcontrol
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/*
/etc/init.d/rpcd restart
```

## Dependencies

- OpenWrt 25.x (tested on 25.12.x)
- `luci-base`
- `nftables` (fw4)
- `dnsmasq` (for DHCP lease device discovery)

## Known Limitations

- **APK packaging**: OpenWrt 25.x uses APK v3 (ADB binary format). The `build-apk.sh` script produces
  the older tar+gzip format which is not compatible. Install via direct file copy for now.
- **No per-service blocking**: This blocks all traffic from the device. For service-level blocking
  (e.g., only block YouTube), use AdGuardHome's per-client blocked services feature.

## Future Improvements

- Bulk enable/disable/delete
