# Timely

<img src="img/timely.svg" align="right" width="150">

**Your terminal calendar. Where time meets the stars.**

![Ruby](https://img.shields.io/badge/language-Ruby-red) [![Gem Version](https://badge.fury.io/rb/timely-calendar.svg)](https://badge.fury.io/rb/timely-calendar) ![Unlicense](https://img.shields.io/badge/license-Unlicense-green) [![Heathrow](https://img.shields.io/badge/companion-Heathrow-blue)](https://github.com/isene/heathrow) ![Stay Amazing](https://img.shields.io/badge/Stay-Amazing-important)

A unified TUI calendar that brings Google Calendar, Outlook/365, and local events into one terminal interface. Built on [rcurses](https://github.com/isene/rcurses), companion to [Heathrow](https://github.com/isene/heathrow).

## Why Timely?

Google Calendar in a browser tab. Outlook in another. Work meetings in Teams. Personal events on your phone. Sound familiar?

Timely puts everything in one terminal view with moon phases, planet visibility, weather, and full keyboard control.

## Features

**Calendar Sources:**
- Google Calendar (OAuth2, full read/write/RSVP)
- Microsoft Outlook/365 (device code auth, Graph API)
- ICS file import with RRULE recurring event expansion
- Local events with create/edit/delete

**Three-Pane Layout:**
- **Top:** Horizontal month strip with week numbers and event markers
- **Middle:** Selected week with half-hour time slots and all-day events
- **Bottom:** Event details with organizer, attendees, description

**Astronomy:**
- Moon phases with emoji symbols and illumination percentage
- Visible planet indicators (Mercury through Saturn) via [ruby-ephemeris](https://github.com/isene/ephemeris)
- Sunrise/sunset times
- Solstices, equinoxes, meteor shower peak dates

**Weather:**
- 7-day forecast from met.no (free, no API key)
- Temperature and conditions shown above each day column

**Integration:**
- Bidirectional with [Heathrow](https://github.com/isene/heathrow) (Z key sends calendar invite to Timely, r replies via Heathrow)
- ICS auto-import from `~/.timely/incoming/`
- Desktop notifications via notify-send (libnotify)
- Cross-source deduplication (no duplicates from ICS + Google)

**UI:**
- Visual 256-color picker for all colors
- Calendar manager (toggle, recolor, remove calendars)
- Preferences popup for colors, work hours, defaults
- Scrollable event detail popup
- Weekend colors (Saturday orange, Sunday red)

## Installation

```bash
gem install timely-calendar
```

### Requirements

- Ruby >= 2.7
- [rcurses](https://github.com/isene/rcurses) gem (>= 5.0)
- sqlite3 gem (>= 1.4)
- Optional: [ruby-ephemeris](https://github.com/isene/ephemeris) for planet data
- Optional: notify-send for desktop notifications

## Quick Start

```bash
timely
```

### Connect Google Calendar

1. Press `G`, enter your Google email
2. Credentials: place your OAuth2 JSON + refresh token in the configured `safe_dir`
   (default: `~/.config/timely/credentials/`)
3. Requires both `https://mail.google.com/` and `https://www.googleapis.com/auth/calendar` scopes

### Connect Outlook/365

1. Register an app in [Azure Portal](https://portal.azure.com/) > App Registrations
2. Add `Calendars.ReadWrite` and `offline_access` (delegated) permissions
3. Enable "Allow public client flows" in Authentication
4. Press `O` in Timely, enter the client ID and tenant ID
5. Follow the device code flow (visit URL, enter code)

## Key Bindings

### Navigation
| Key | Action |
|-----|--------|
| `d` / `RIGHT` | Next day |
| `D` / `LEFT` | Previous day |
| `w` / `W` | Next / previous week |
| `m` / `M` | Next / previous month |
| `y` / `Y` | Next / previous year |
| `UP` / `DOWN` | Select time slot (scrolls) |
| `PgUp` / `PgDn` | Jump 10 time slots |
| `HOME` | Top (all-day area) |
| `END` | Bottom (23:30) |
| `e` / `E` | Jump to next / previous event |
| `t` | Go to today |
| `g` | Go to date (yyyy-mm-dd, Mar, 21, 2026) |

### Events
| Key | Action |
|-----|--------|
| `n` | New event |
| `ENTER` | Edit event |
| `x` / `DEL` | Delete event |
| `v` | View event details (scrollable popup) |
| `a` | Accept invite (pushes RSVP to Google/Outlook) |
| `Ctrl-Y` | Copy event to clipboard |
| `r` | Reply via Heathrow |

### Sources & Settings
| Key | Action |
|-----|--------|
| `i` | Import ICS file |
| `G` | Setup Google Calendar |
| `O` | Setup Outlook/365 |
| `S` | Sync now (background) |
| `C` | Calendar manager |
| `P` | Preferences |
| `?` | Help |
| `q` | Quit |

## Configuration

Config file: `~/.timely/config.yml`

```yaml
location:
  lat: 59.9139
  lon: 10.7522
timezone_offset: 1
work_hours:
  start: 8
  end: 17
week_starts_on: monday
default_view: month
default_calendar: 1

google:
  safe_dir: ~/.config/timely/credentials
  sync_interval: 300

outlook:
  client_id: ''
  tenant_id: common

notifications:
  enabled: true
  default_alarm: 15

colors:
  selected_bg_a: 235
  selected_bg_b: 234
  alt_bg_a: 233
  alt_bg_b: 0
  current_month_bg: 233
  saturday: 208
  sunday: 167
  today_fg: 232
  today_bg: 246
  slot_selected_bg: 237
  info_bg: 235
  status_bg: 235
```

## Heathrow Integration

Timely is the calendar companion to [Heathrow](https://github.com/isene/heathrow), the unified messaging TUI.

**From Heathrow:** Press `Z` on a calendar invite email to open it in Timely. The ICS data is auto-imported and Timely jumps to the event date.

**From Timely:** Press `r` on an event to compose a reply via Heathrow.

**Auto-import:** Drop `.ics` files in `~/.timely/incoming/` and they're imported on next Timely startup.

## License

Released into the Public Domain ([Unlicense](LICENSE)).

## Author

[Geir Isene](https://isene.com) with [Claude Code](https://claude.ai/claude-code)
