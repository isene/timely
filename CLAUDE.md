# CLAUDE.md - Development Notes for Timely

## Project Vision

**Timely** - Terminal calendar companion to Heathrow.

A TUI calendar application built on rcurses, following the same patterns as Heathrow. View, navigate, and manage calendars with month, week, day, and year views.

## Architecture

Built on rcurses (Ruby TUI library). Same pane layout as Heathrow and RTFM.

### File Structure
```
timely/
  bin/timely              # Entry point
  lib/timely.rb           # Module loader
  lib/timely/
    version.rb            # Version constant
    database.rb           # SQLite database (events, calendars, settings)
    config.rb             # YAML config manager (~/.timely/config.yml)
    event.rb              # Event model
    astronomy.rb          # Moon phase calculations
    ui/
      panes.rb            # Pane layout (top, left, right, bottom)
      application.rb      # Main app class, input loop, rendering
      views/
        month.rb          # Month calendar grid
        year.rb           # 12 mini-months
        week.rb           # 7-column hourly grid
        day.rb            # 30-min time slots
    sources/              # Calendar source plugins (future)
    sync/                 # Sync engines (future)
  docs/                   # Documentation
```

### Key Bindings
- h/l or LEFT/RIGHT: navigate days/months
- j/k or DOWN/UP: navigate weeks/hours
- 1-6: switch views (year, quarter, month, week, workweek, day)
- T: go to today
- g: go to specific date
- n: new event (placeholder)
- w: cycle pane width
- B: toggle border
- q: quit

## Critical rcurses Notes

### Key Input
rcurses returns special keys as STRINGS:
- "UP", "DOWN", "LEFT", "RIGHT"
- "ENTER", "ESC", "SPACE"
- "PgUP", "PgDOWN", "HOME", "END"
- "BACK" (backspace)

### Pane API
- `Rcurses::Pane.new(x, y, w, h, fg, bg)` - create pane
- `pane.text = string` then `pane.refresh` - set and display content
- `pane.ask(prompt, default)` - get user input
- `pane.border = true/false`
- `pane.ix = 0` - scroll position

### String Extensions
- `"text".fg(color)` - foreground color (256-color int)
- `"text".bg(color)` - background color
- `"text".b` - bold
- `"text".u` - underline
- `"text".r` - reverse video

### Initialization
- Call `Rcurses.init!` before anything
- Terminal size: `IO.console.winsize` returns `[height, width]`
- Flush stdin: `$stdin.getc while $stdin.wait_readable(0)`

### Rules
- No raw ANSI codes; use rcurses methods only
- Use `require 'rcurses'` (the gem)
- All dates use Ruby's Date class
- All times stored as Unix timestamps in DB

## Current Status

**Phase 0:** Foundation (complete)
- Core architecture, database, config
- Month, week, day, year views
- Moon phase display
- Navigation and view switching

**Future Phases:**
1. CalDAV sync (Google Calendar, iCloud, etc.)
2. Event creation and editing
3. Recurring events
4. Weather integration
5. Notifications and reminders
