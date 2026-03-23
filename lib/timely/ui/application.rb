#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rcurses'
require 'io/wait'
require 'date'

module Timely
  class Application
    include Rcurses
    include Rcurses::Input
    include Rcurses::Cursor
    include UI::Panes

    def initialize
      @db = Database.new
      @config = Config.new
      @running = false
      @selected_date = Date.today
      @selected_event_index = 0
      now = Time.now
      @selected_slot = now.hour * 2 + (now.min >= 30 ? 1 : 0)
      @slot_offset = [@selected_slot - 5, 0].max  # Show a few rows above current time
      @events_by_date = {}
    end

    def run
      Rcurses.init!
      Rcurses.clear_screen

      setup_display
      create_panes

      load_events_for_range

      # Auto-import ICS files from incoming directory
      incoming_count = Sources::IcsFile.watch_incoming(@db)
      load_events_for_range if incoming_count > 0

      render_all

      # Start background sync poller for Google Calendar
      @poller = Sync::Poller.new(@db, @config)
      @poller.start

      # Flush stdin before loop
      $stdin.getc while $stdin.wait_readable(0)

      @running = true
      loop do
        chr = getchr(2, flush: false)
        if chr
          handle_input(chr)
        else
          # No input received (timeout); check if poller has new data
          if @poller&.needs_refresh?
            @poller.clear_refresh_flag
            load_events_for_range
            render_all
          end
        end
        break unless @running
      end
    ensure
      @poller&.stop
      Cursor.show
    end

    private

    # --- Input handling ---

    def handle_input(chr)
      case chr
      when 'y'
        @selected_date = safe_date(@selected_date.year + 1, @selected_date.month, @selected_date.day)
        date_changed
      when 'Y'
        @selected_date = safe_date(@selected_date.year - 1, @selected_date.month, @selected_date.day)
        date_changed
      when 'm'
        @selected_date = @selected_date >> 1
        date_changed
      when 'M'
        @selected_date = @selected_date << 1
        date_changed
      when 'w'
        @selected_date += 7
        date_changed
      when 'W'
        @selected_date -= 7
        date_changed
      when 'd', 'l', 'RIGHT'
        @selected_date += 1
        date_changed
      when 'D', 'h', 'LEFT'
        @selected_date -= 1
        date_changed
      when 'DOWN'
        move_slot_down
      when 'UP'
        move_slot_up
      when 'PgDOWN'
        page_slots_down
      when 'PgUP'
        page_slots_up
      when 'HOME'
        go_slot_top
      when 'END'
        go_slot_bottom
      when 'j'
        select_next_event_on_day
      when 'k'
        select_prev_event_on_day
      when 'e'
        jump_to_next_event
      when 'E'
        jump_to_prev_event
      when 't'
        @selected_date = Date.today
        @selected_event_index = 0
        date_changed
      when 'g'
        go_to_date
      when 'n'
        create_event
      when 'ENTER'
        edit_event
      when 'x', 'DEL'
        delete_event
      when 'a'
        accept_invite
      when 'r'
        show_feedback("Reply via Heathrow: not yet implemented", 226)
      when 'i'
        import_ics_file
      when 'G'
        setup_google_calendar
      when 'S'
        manual_sync
      when 'C'
        show_calendars
      when 'P'
        show_preferences
      when '?'
        show_help
      when 'q'
        @running = false
      end
    end

    # --- Time slot navigation ---

    # @selected_slot: 0-47 = time slots (00:00-23:30)
    #                 negative = all-day event rows (-1 = first, -2 = second...)
    def allday_count
      events = events_on_selected_day
      events.count { |e| e['all_day'].to_i == 1 }
    end

    def min_slot
      n = allday_count
      n > 0 ? -n : 0
    end

    def move_slot_down
      work_start = @config.get('work_hours.start', 8) rescue 8
      @selected_slot ||= work_start * 2
      if @selected_slot >= 47
        @selected_slot = min_slot
        @slot_offset = 0
      else
        @selected_slot += 1
      end
      # Scroll time area
      if @selected_slot >= 0
        allday_rows = allday_count > 0 ? allday_count + 1 : 0
        available_rows = @panes[:mid].h - 3 - allday_rows
        available_rows = [available_rows, 1].max
        if @selected_slot - @slot_offset >= available_rows
          @slot_offset = @selected_slot - available_rows + 1
        end
      end
      render_mid_pane
      render_bottom_pane
    end

    def move_slot_up
      work_start = @config.get('work_hours.start', 8) rescue 8
      @selected_slot ||= work_start * 2
      if @selected_slot <= min_slot
        @selected_slot = 47
        allday_rows = allday_count > 0 ? allday_count + 1 : 0
        available_rows = @panes[:mid].h - 3 - allday_rows
        available_rows = [available_rows, 1].max
        @slot_offset = [48 - available_rows, 0].max
      else
        @selected_slot -= 1
      end
      if @selected_slot >= 0 && @selected_slot < @slot_offset
        @slot_offset = @selected_slot
      end
      render_mid_pane
      render_bottom_pane
    end

    def page_slots_down
      10.times { move_slot_down }
    end

    def page_slots_up
      10.times { move_slot_up }
    end

    def go_slot_top
      @selected_slot = min_slot
      @slot_offset = 0
      render_mid_pane
      render_bottom_pane
    end

    def go_slot_bottom
      @selected_slot = 47
      allday_rows = allday_count > 0 ? allday_count + 1 : 0
      available_rows = @panes[:mid].h - 3 - allday_rows
      available_rows = [available_rows, 1].max
      @slot_offset = [48 - available_rows, 0].max
      render_mid_pane
      render_bottom_pane
    end

    # --- Date/event state changes ---

    def date_changed
      @selected_event_index = 0
      load_events_for_range
      render_all
    end

    def safe_date(year, month, day)
      # Clamp day to valid range for the target month
      last_day = Date.new(year, month, -1).day
      Date.new(year, month, [day, last_day].min)
    rescue Date::Error
      Date.today
    end

    # --- Event navigation ---

    def events_on_selected_day
      @events_by_date[@selected_date] || []
    end

    # Find the event at the currently selected time slot
    def event_at_selected_slot
      return nil unless @selected_slot
      events = events_on_selected_day.sort_by { |e| e['start_time'].to_i }

      if @selected_slot < 0
        # Negative slot = all-day event row
        allday = events.select { |e| e['all_day'].to_i == 1 }
        idx = @selected_slot.abs - 1
        return allday[idx]
      end

      hour = @selected_slot / 2
      minute = (@selected_slot % 2) * 30
      slot_start = Time.new(@selected_date.year, @selected_date.month, @selected_date.day, hour, minute, 0).to_i
      slot_end = slot_start + 1800
      events.find do |e|
        next if e['all_day'].to_i == 1
        es = e['start_time'].to_i
        ee = e['end_time'].to_i
        es < slot_end && ee > slot_start
      end
    end

    def select_next_event_on_day
      events = events_on_selected_day
      return if events.empty?
      @selected_event_index = (@selected_event_index + 1) % events.length
      render_mid_pane
      render_bottom_pane
    end

    def select_prev_event_on_day
      events = events_on_selected_day
      return if events.empty?
      @selected_event_index = (@selected_event_index - 1) % events.length
      render_mid_pane
      render_bottom_pane
    end

    def jump_to_next_event
      events = events_on_selected_day
      # If there are more events on the current day after the selected one, go to next
      if events.length > 0 && @selected_event_index < events.length - 1
        @selected_event_index += 1
        render_mid_pane
        render_bottom_pane
        return
      end

      # Scan forward day by day (up to 365 days)
      (1..365).each do |offset|
        check_date = @selected_date + offset
        day_events = @db.get_events_for_date(check_date)
        if day_events && !day_events.empty?
          @selected_date = check_date
          @selected_event_index = 0
          date_changed
          return
        end
      end

      show_feedback("No more events found within the next year", 245)
    end

    def jump_to_prev_event
      events = events_on_selected_day
      # If there are more events on the current day before the selected one, go to prev
      if events.length > 0 && @selected_event_index > 0
        @selected_event_index -= 1
        render_mid_pane
        render_bottom_pane
        return
      end

      # Scan backward day by day (up to 365 days)
      (1..365).each do |offset|
        check_date = @selected_date - offset
        day_events = @db.get_events_for_date(check_date)
        if day_events && !day_events.empty?
          @selected_date = check_date
          @selected_event_index = day_events.length - 1
          date_changed
          return
        end
      end

      show_feedback("No earlier events found within the past year", 245)
    end

    # --- Data loading ---

    def load_events_for_range
      # Load events covering visible months (a generous range around the selected date)
      range_start = Date.new(@selected_date.year, @selected_date.month, 1) << 3
      range_end = Date.new(@selected_date.year, @selected_date.month, -1) >> 3

      start_ts = Time.new(range_start.year, range_start.month, range_start.day, 0, 0, 0).to_i
      end_ts = Time.new(range_end.year, range_end.month, range_end.day, 23, 59, 59).to_i

      raw_events = @db.get_events_in_range(start_ts, end_ts)

      @events_by_date = {}
      raw_events.each do |evt|
        st = Time.at(evt['start_time'].to_i).to_date
        et = evt['end_time'] ? Time.at(evt['end_time'].to_i).to_date : st

        (st..et).each do |d|
          next unless d >= range_start && d <= range_end
          @events_by_date[d] ||= []
          @events_by_date[d] << evt
        end
      end

      # Clamp selected event index
      events = events_on_selected_day
      @selected_event_index = 0 if events.empty?
      @selected_event_index = events.length - 1 if @selected_event_index >= events.length

      # Load weather (cached, background-safe)
      lat = @config.get('location.lat', 59.9139)
      lon = @config.get('location.lon', 10.7522)
      @weather_forecast ||= {}
      if @weather_forecast.empty?
        @weather_forecast = Weather.fetch(lat, lon, @db) rescue {}
      end
    end

    # --- Rendering ---

    def render_all
      # Check for terminal resize
      old_h, old_w = @h, @w
      setup_display
      if @h != old_h || @w != old_w
        Rcurses.clear_screen
        create_panes
      end

      render_info_bar
      render_top_pane
      render_mid_pane
      render_bottom_pane
      render_status_bar
    end

    # Info bar: top row with bg color
    def render_info_bar
      title = " Timely".b
      date_str = @selected_date.strftime("  %A, %B %d, %Y")
      phase = Astronomy.moon_phase(@selected_date)
      moon = "  #{phase[:symbol]} #{phase[:phase_name]} (#{(phase[:illumination] * 100).round}%)"

      lat = @config.get('location.lat', 59.9139)
      lon = @config.get('location.lon', 10.7522)
      tz = @config.get('timezone_offset', 1)

      # Sunrise/sunset (yellow sun)
      sun = Astronomy.sun_times(@selected_date, lat, lon, tz)
      sun_color = Astronomy::BODY_COLORS['sun']
      sun_str = sun ? "  " + "\u2600".fg(sun_color) + "\u2191#{sun[:rise]} " + "\u2600".fg(sun_color) + "\u2193#{sun[:set]}" : ""

      # Visible planets (cached per date)
      @_cached_planets_date ||= nil
      if @_cached_planets_date != @selected_date
        @_cached_planets = Astronomy.visible_planets(@selected_date, lat, lon, tz)
        @_cached_planets_date = @selected_date
      end
      planets = @_cached_planets || []
      planet_str = planets.any? ? "  " + planets.map { |p|
        color = Astronomy::BODY_COLORS[p[:name].downcase] || '888888'
        p[:symbol].fg(color)
      }.join(" ") : ""

      @panes[:info].text = title + date_str + moon + sun_str + planet_str
      @panes[:info].refresh
    end

    # Status bar: bottom row with key hints
    def render_status_bar
      keys = "d/D:Day  w/W:Week  m/M:Month  y/Y:Year  e/E:Event  n:New  g:GoTo  t:Today  i:Import  G:Google  S:Sync  C:Cal  P:Prefs  ?:Help  q:Quit"
      @panes[:status].text = " " + keys
      @panes[:status].refresh
    end

    # Top pane: horizontal strip of mini-month calendars
    def render_top_pane
      today = Date.today
      month_width = 26  # 25 chars + 1 space separator
      months_visible = [@w / month_width, 1].max

      offset = months_visible / 2 + 1  # Shift left to show one more future month

      months = []
      months_visible.times do |i|
        m_offset = i - offset
        d = @selected_date >> m_offset
        months << [d.year, d.month]
      end

      # Render each mini-month; current month gets bg color
      rendered = months.map do |year, month|
        sel_day = (year == @selected_date.year && month == @selected_date.month) ? @selected_date.day : nil
        is_current = (year == @selected_date.year && month == @selected_date.month)
        tbg = @config.get('colors.today_bg', 236)
        lines = UI::Views::Month.render_mini_month(year, month, sel_day, today, @events_by_date, month_width - 1, today_bg: tbg)
        # Apply bg to current month
        if is_current
          lines.map { |l| l.bg(@config.get('colors.current_month_bg', 233)) }
        else
          lines
        end
      end

      max_lines = rendered.map(&:length).max || 0
      combined_lines = [""]  # One row top padding

      max_lines.times do |row|
        parts = rendered.map do |month_lines|
          line = month_lines[row] || ""
          pure_len = Rcurses.display_width(line.respond_to?(:pure) ? line.pure : line)
          padding = (month_width - 1) - pure_len
          padding = 0 if padding < 0
          line + " " * padding
        end
        combined_lines << " " + parts.join(" ")
      end

      while combined_lines.length < @panes[:top].h
        combined_lines << ""
      end

      @panes[:top].text = combined_lines.join("\n")
      @panes[:top].full_refresh
    end

    # Mid pane: week view with time column + day columns
    def render_mid_pane
      week_start = @selected_date - (@selected_date.cwday - 1)
      time_col = 6  # "HH:MM " width
      gap = 1       # gap between day columns
      day_col = (@w - time_col - gap * 6) / 7  # 7 days, 6 gaps between them
      day_col = [day_col, 8].max
      sel_bg = @config.get('colors.selected_bg_a', 235)
      alt_bg_a = @config.get('colors.alt_bg_a', 233)
      alt_bg_b = @config.get('colors.alt_bg_b', 0)

      lines = []

      # Weather row above day headers
      weather_parts = [" " * time_col]
      7.times do |i|
        day = week_start + i
        w_str = Weather.short_for_date(@weather_forecast || {}, day)
        w_str ||= ""
        pure_len = Rcurses.display_width(w_str)
        pad = [day_col - pure_len, 0].max
        weather_parts << w_str.fg(245) + " " * pad
      end
      lines << weather_parts.join(" ")

      # Column headers: week number + time column + day headers
      wk_num = "W#{week_start.cweek}".fg(238)
      header_parts = [wk_num + " " * [time_col - 3, 1].max]
      7.times do |i|
        day = week_start + i
        header = "#{day.strftime('%a')} #{day.day}"
        is_sel = (day == @selected_date)
        is_today = (day == Date.today)

        # Base color: weekend colors or default gray
        base_color = if day.sunday?
          @config.get('colors.sunday', 167)
        elsif day.saturday?
          @config.get('colors.saturday', 208)
        else
          245
        end

        sel_hdr_bg = @config.get('colors.selected_bg_a', 235)
        header = if is_sel
          header.b.u.fg(base_color).bg(sel_hdr_bg)
        elsif is_today
          header.b.u.fg(base_color)
        else
          header.fg(base_color)
        end

        pure_len = Rcurses.display_width(header.respond_to?(:pure) ? header.pure : header)
        pad = [day_col - pure_len, 0].max
        padding = is_sel ? " ".bg(sel_hdr_bg) * pad : " " * pad
        header_parts << header + padding
      end
      lines << header_parts.join(" ")
      lines << ("-" * @w).fg(238)

      # Gather events for each day, split all-day from timed
      week_events = []
      week_allday = []
      7.times do |i|
        day = week_start + i
        all = (@events_by_date[day] || []).sort_by { |e| e['start_time'].to_i }
        week_allday << all.select { |e| e['all_day'].to_i == 1 }
        week_events << all.reject { |e| e['all_day'].to_i == 1 }
      end

      # All-day event row(s) above time grid
      max_allday = week_allday.map(&:size).max || 0
      if max_allday > 0
        max_allday.times do |row|
          allday_slot = -(row + 1)  # -1, -2, ...
          is_row_selected = (@selected_slot == allday_slot)
          parts = [is_row_selected ? "  All".fg(255).b + " " : " " * time_col]
          sel_ad_bg = @config.get('colors.selected_bg_a', 235)
          slot_bg = @config.get('colors.slot_selected_bg', 237)
          7.times do |col|
            evt = week_allday[col][row]
            day = week_start + col
            is_sel = (day == @selected_date)
            is_at = is_sel && is_row_selected
            cell_bg = is_at ? slot_bg : (is_sel ? sel_ad_bg : nil)
            if evt
              title = evt['title'] || "(No title)"
              color = evt['calendar_color'] || 39
              marker = is_at ? ">" : " "
              entry = "#{marker}#{title}"[0, day_col - 1]
              cell = cell_bg ? entry.fg(color).b.bg(cell_bg) : entry.fg(color)
            else
              cell = cell_bg ? " ".bg(cell_bg) : " "
            end
            pure_len = Rcurses.display_width(cell.respond_to?(:pure) ? cell.pure : cell)
            pad = [day_col - pure_len, 0].max
            pad_str = is_sel ? " ".bg(sel_ad_bg) * pad : " " * pad
            parts << cell + pad_str
          end
          lines << parts.join(" ")
        end
        lines << ("-" * @w).fg(238)
      end

      # Build half-hour time slots with scroll offset
      work_start = @config.get('work_hours.start', 8) rescue 8
      extra_rows = max_allday > 0 ? max_allday + 1 : 0  # allday rows + separator
      available_rows = @panes[:mid].h - 3 - extra_rows
      # Default slot offset to work_start if not set
      @slot_offset ||= work_start * 2
      # Clamp offset
      @slot_offset = [[@slot_offset, 0].max, [48 - available_rows, 0].max].min

      slots = []
      (@slot_offset...[@slot_offset + available_rows, 48].min).each do |slot|
        hour = slot / 2
        minute = (slot % 2) * 30
        slots << [hour, minute, slot]
      end

      slots.each_with_index do |(hour, minute, slot_idx), row|
        is_slot_selected = (@selected_slot == slot_idx)
        row_bg = row.even? ? alt_bg_a : alt_bg_b

        # Time label: highlight if selected
        time_label = format("%02d:%02d ", hour, minute)
        time_label = is_slot_selected ? time_label.fg(255).b : time_label.fg(238)

        parts = [time_label]
        7.times do |col|
          day = week_start + col
          is_sel = (day == @selected_date)
          sel_alt_a = @config.get('colors.selected_bg_a', 235)
          sel_alt_b = @config.get('colors.selected_bg_b', 234)
          cell_bg_base = row.even? ? alt_bg_a : alt_bg_b
          if is_sel && is_slot_selected
            cell_bg = @config.get('colors.slot_selected_bg', 237)
          elsif is_sel
            cell_bg = row.even? ? sel_alt_a : sel_alt_b
          else
            cell_bg = cell_bg_base
          end

          # Find event at this time slot
          day_ts_start = Time.new(day.year, day.month, day.day, hour, minute, 0).to_i
          day_ts_end = day_ts_start + 1800  # 30 min slot

          evt = week_events[col].find do |e|
            es = e['start_time'].to_i
            ee = e['end_time'].to_i
            es < day_ts_end && ee > day_ts_start
          end

          if evt
            is_at_slot = is_sel && is_slot_selected
            marker = is_at_slot ? ">" : " "
            title = evt['title'] || "(No title)"
            color = evt['calendar_color'] || 39
            entry = "#{marker}#{title}"
            entry = entry[0, day_col - 1] + "." if entry.length > day_col
            cell = is_at_slot ? entry.fg(color).b.bg(cell_bg) : entry.fg(color).bg(cell_bg)
          else
            cell = " ".bg(cell_bg)
          end

          pure_len = Rcurses.display_width(cell.respond_to?(:pure) ? cell.pure : cell)
          pad = [day_col - pure_len, 0].max
          parts << cell + " ".bg(cell_bg) * pad
        end
        lines << parts.join(" ")
      end

      while lines.length < @panes[:mid].h
        lines << ""
      end

      @panes[:mid].text = lines.join("\n")
      @panes[:mid].full_refresh
    end

    # Bottom pane: event details or day summary
    def render_bottom_pane
      lines = []
      events = events_on_selected_day

      # Separator
      lines << ("-" * @w).fg(238)

      evt = event_at_selected_slot
      if evt
        color = evt['calendar_color'] || 39

        # Title
        lines << " #{evt['title'] || '(No title)'}".fg(color).b

        # Date and time
        if evt['all_day'].to_i == 1
          lines << " #{@selected_date.strftime('%a %Y-%m-%d')}  All day".fg(252)
        else
          st = Time.at(evt['start_time'].to_i)
          time_str = " #{st.strftime('%a %Y-%m-%d  %H:%M')}"
          if evt['end_time']
            et = Time.at(evt['end_time'].to_i)
            time_str += " - #{et.strftime('%H:%M')}"
          end
          lines << time_str.fg(252)
        end

        # Location
        if evt['location'] && !evt['location'].to_s.strip.empty?
          loc = evt['location'].to_s
          loc = loc[0, @w - 4] if loc.length > @w - 4
          lines << " Location: #{loc}".fg(245)
        end

        # Organizer
        if evt['organizer'] && !evt['organizer'].to_s.strip.empty?
          lines << " Organizer: #{evt['organizer']}".fg(245)
        end

        # Status
        status_parts = []
        status_parts << "Status: #{evt['status']}" if evt['status']
        status_parts << "My status: #{evt['my_status']}" if evt['my_status']
        lines << " #{status_parts.join('  |  ')}".fg(245) unless status_parts.empty?

        # Calendar name
        cal_name = evt['calendar_name'] || 'Unknown'
        lines << " Calendar: #{cal_name}".fg(240)

        # Description (truncated)
        if evt['description'] && !evt['description'].to_s.strip.empty?
          desc = evt['description'].to_s.gsub("\n", " ").strip
          desc = desc[0, @w - 4] if desc.length > @w - 4
          lines << ""
          lines << " #{desc}".fg(248)
        end

      else
        # No events: show day summary
        lines << " #{@selected_date.strftime('%A, %B %d, %Y')}".b

        # Astronomical events (solstices, meteor showers, etc.)
        lat = @config.get('location.lat', 59.9139)
        lon = @config.get('location.lon', 10.7522)
        tz = @config.get('timezone_offset', 1)
        astro = Astronomy.astro_events(@selected_date, lat, lon, tz)
        astro.each { |evt| lines << " #{evt}".fg(180) } if astro.any?

        lines << ""
        lines << " No events scheduled".fg(240)
      end

      # Pad to fill pane
      while lines.length < @panes[:bottom].h
        lines << ""
      end

      @panes[:bottom].text = lines.join("\n")
      @panes[:bottom].full_refresh
    end

    # --- Actions ---

    def go_to_date
      input = bottom_ask("Go to: ", "")
      return if input.nil? || input.strip.empty?

      input = input.strip

      parsed = parse_go_to_input(input)
      if parsed
        @selected_date = parsed
        @selected_event_index = 0
        date_changed
      else
        show_feedback("Could not parse date: #{input}", 196)
      end
    end

    def parse_go_to_input(input)
      return Date.today if input.downcase == "today"

      # Exact date: yyyy-mm-dd
      if input =~ /\A\d{4}-\d{1,2}-\d{1,2}\z/
        return Date.parse(input) rescue nil
      end

      # Year only: 4 digits
      if input =~ /\A\d{4}\z/
        return Date.new(input.to_i, 1, 1) rescue nil
      end

      # Month name or abbreviation
      month_names = %w[january february march april may june july august september october november december]
      month_abbrevs = %w[jan feb mar apr may jun jul aug sep oct nov dec]

      lower = input.downcase
      month_names.each_with_index do |name, i|
        if lower == name || lower == month_abbrevs[i]
          return Date.new(@selected_date.year, i + 1, 1) rescue nil
        end
      end

      # Single number 1-12 could be month, 1-31 could be day
      if input =~ /\A\d{1,2}\z/
        num = input.to_i
        if num >= 1 && num <= 31
          # Treat as day in current month
          last_day = Date.new(@selected_date.year, @selected_date.month, -1).day
          day = [num, last_day].min
          return Date.new(@selected_date.year, @selected_date.month, day) rescue nil
        end
      end

      # Last resort: try Date.parse
      Date.parse(input) rescue nil
    end

    def create_event
      default_time = @selected_slot ? format("%02d:%02d", @selected_slot / 2, (@selected_slot % 2) * 30) : "09:00"
      calendars = @db.get_calendars
      default_cal_id = @config.get('default_calendar', 1)
      cal = calendars.find { |c| c['id'] == default_cal_id } || calendars.first
      return show_feedback("No calendars configured", 196) unless cal
      cal_color = cal['color'] || 39

      # Calendar picker (if multiple)
      if calendars.size > 1
        cal_list = calendars.each_with_index.map { |c, i| "#{i + 1}:#{c['name']}" }.join("  ")
        default_idx = calendars.index(cal) || 0
        blank_bottom(" New Event".fg(cal_color).b)
        pick = bottom_ask(" Calendar (#{cal_list}): ", (default_idx + 1).to_s)
        return cancel_create if pick.nil?
        idx = pick.strip.to_i - 1
        cal = calendars[idx] if idx >= 0 && idx < calendars.size
        cal_color = cal['color'] || 39
      end

      blank_bottom(" New Event on #{@selected_date.strftime('%A, %B %d, %Y')}".fg(cal_color).b)
      title = bottom_ask(" Title: ", "")
      return cancel_create if title.nil? || title.strip.empty?

      blank_bottom(" #{title.strip}".fg(cal_color).b)
      time_str = bottom_ask(" Start time (HH:MM or 'all day'): ", default_time)
      return cancel_create if time_str.nil?

      all_day = (time_str.strip.downcase == 'all day')

      if all_day
        start_ts = Time.new(@selected_date.year, @selected_date.month, @selected_date.day, 0, 0, 0).to_i
        end_ts = start_ts + 86400
      else
        parts = time_str.strip.split(':')
        hour = parts[0].to_i
        minute = (parts[1] || 0).to_i
        start_ts = Time.new(@selected_date.year, @selected_date.month, @selected_date.day, hour, minute, 0).to_i

        blank_bottom(" #{title.strip} at #{time_str.strip}".fg(cal_color).b)
        dur_str = bottom_ask(" Duration in minutes: ", "60")
        return cancel_create if dur_str.nil?
        duration = dur_str.strip.to_i
        duration = 60 if duration <= 0
        end_ts = start_ts + duration * 60
      end

      # Location
      blank_bottom(" #{title.strip}".fg(cal_color).b)
      location = bottom_ask(" Location (Enter to skip): ", "")
      location = nil if location.nil? || location.strip.empty?

      # Invitees
      blank_bottom(" #{title.strip}".fg(cal_color).b)
      invitees_str = bottom_ask(" Invite (comma-separated emails, Enter to skip): ", "")
      attendees = nil
      if invitees_str && !invitees_str.strip.empty?
        attendees = invitees_str.strip.split(',').map { |e| { 'email' => e.strip } }
      end

      # Attachments via rtfm --pick
      blank_bottom(" #{title.strip}".fg(cal_color).b)
      attach_str = bottom_ask(" Add attachments? (y/N): ", "")
      attachments = nil
      if attach_str&.strip&.downcase == 'y'
        files = run_rtfm_picker
        if files && !files.empty?
          attachments = files.map { |f| { 'path' => f } }
        end
      end

      @db.save_event(
        title: title.strip,
        start_time: start_ts,
        end_time: end_ts,
        all_day: all_day,
        calendar_id: cal['id'],
        location: location&.strip,
        attendees: attendees,
        metadata: attachments ? { 'attachments' => attachments } : nil,
        status: 'confirmed'
      )

      load_events_for_range
      render_all
      msg = "Event created: #{title.strip}"
      msg += " (invites will be sent when calendar sync is configured)" if attendees
      show_feedback(msg, cal_color)
    end

    def blank_bottom(header = "")
      lines = []
      lines << ("-" * @w).fg(238)
      lines << ""
      lines << header unless header.empty?
      while lines.length < @panes[:bottom].h
        lines << ""
      end
      @panes[:bottom].text = lines.join("\n")
      @panes[:bottom].full_refresh
    end

    def bottom_ask(prompt, default = "")
      # Prompt pane below separator + header + blank line
      prompt_y = @panes[:bottom].y + 3
      prompt_pane = Rcurses::Pane.new(1, prompt_y, @w, 1)
      prompt_pane.border = false
      prompt_pane.scroll = false
      result = prompt_pane.ask(prompt, default)
      result
    end

    def cancel_create
      render_all
    end

    def run_rtfm_picker
      require 'shellwords'
      pick_file = "/tmp/timely_pick_#{Process.pid}.txt"
      File.delete(pick_file) if File.exist?(pick_file)

      system("stty sane 2>/dev/null")
      Cursor.show
      system("rtfm --pick=#{Shellwords.escape(pick_file)}")
      $stdin.raw!
      $stdin.echo = false
      Cursor.hide
      Rcurses.clear_screen
      setup_display
      create_panes
      render_all

      if File.exist?(pick_file)
        files = File.read(pick_file).lines.map(&:strip).reject(&:empty?)
        File.delete(pick_file) rescue nil
        files.select { |f| File.exist?(f) && File.file?(f) }
      else
        []
      end
    end

    def edit_event
      evt = event_at_selected_slot
      return show_feedback("No event at this time slot", 245) unless evt

      blank_bottom(" Edit Event".b)
      new_title = bottom_ask(" Title: ", evt['title'] || "")
      return if new_title.nil?

      @db.save_event(
        id: evt['id'],
        calendar_id: evt['calendar_id'],
        external_id: evt['external_id'],
        title: new_title.strip,
        description: evt['description'],
        location: evt['location'],
        start_time: evt['start_time'],
        end_time: evt['end_time'],
        all_day: evt['all_day'].to_i == 1,
        timezone: evt['timezone'],
        recurrence_rule: evt['recurrence_rule'],
        status: evt['status'],
        organizer: evt['organizer'],
        attendees: evt['attendees'],
        my_status: evt['my_status'],
        alarms: evt['alarms'],
        metadata: evt['metadata']
      )

      load_events_for_range
      render_all
      show_feedback("Event updated", 156)
    end

    def delete_event
      events = events_on_selected_day
      evt = event_at_selected_slot
      return show_feedback("No event at this time slot", 245) unless evt

      blank_bottom(" Delete Event".b)
      confirm = bottom_ask(" Delete '#{evt['title']}'? (y/n): ", "")
      return unless confirm&.strip&.downcase == 'y'

      @db.delete_event(evt['id'])

      load_events_for_range
      render_all
      show_feedback("Event deleted", 156)
    end

    def accept_invite
      evt = event_at_selected_slot
      return show_feedback("No event at this time slot", 245) unless evt

      @db.save_event(
        id: evt['id'],
        calendar_id: evt['calendar_id'],
        external_id: evt['external_id'],
        title: evt['title'],
        description: evt['description'],
        location: evt['location'],
        start_time: evt['start_time'],
        end_time: evt['end_time'],
        all_day: evt['all_day'].to_i == 1,
        timezone: evt['timezone'],
        recurrence_rule: evt['recurrence_rule'],
        status: evt['status'],
        organizer: evt['organizer'],
        attendees: evt['attendees'],
        my_status: 'accepted',
        alarms: evt['alarms'],
        metadata: evt['metadata']
      )

      # Push RSVP to Google Calendar if applicable
      push_rsvp_to_google(evt)

      load_events_for_range
      render_all
      show_feedback("Invite accepted", 156)
    end

    def push_rsvp_to_google(evt)
      cal = @db.get_calendars(false).find { |c| c['id'] == evt['calendar_id'] }
      return unless cal && cal['source_type'] == 'google' && evt['external_id']

      config = cal['source_config']
      config = JSON.parse(config) if config.is_a?(String)
      return unless config.is_a?(Hash)

      google = Sources::Google.new(config['email'], safe_dir: config['safe_dir'] || '/home/.safe/mail')
      return unless google.get_access_token

      gcal_id = config['google_calendar_id'] || config['email']
      # Google handles RSVP via the attendees list; we patch the event
      google.update_event(gcal_id, evt['external_id'], {
        title: evt['title'],
        start_time: evt['start_time'].to_i,
        end_time: evt['end_time'].to_i,
        all_day: evt['all_day'].to_i == 1,
        attendees: evt['attendees']
      })
    rescue => e
      # Silently fail; local status is already updated
      nil
    end

    # --- ICS Import ---

    def import_ics_file
      blank_bottom(" Import ICS File".b)
      path = bottom_ask(" File path: ", "")
      return cancel_create if path.nil? || path.strip.empty?

      path = File.expand_path(path.strip)
      unless File.exist?(path)
        show_feedback("File not found: #{path}", 196)
        return
      end

      result = Sources::IcsFile.import_file(path, @db)
      load_events_for_range
      render_all
      msg = "Imported #{result[:imported]} event(s)"
      msg += ", skipped #{result[:skipped]}" if result[:skipped] > 0
      msg += " (#{result[:error]})" if result[:error]
      show_feedback(msg, result[:error] ? 196 : 156)
    end

    # --- Google Calendar ---

    def setup_google_calendar
      blank_bottom(" Google Calendar Setup".b.fg(39))
      email = bottom_ask(" Google email: ", "")
      return cancel_create if email.nil? || email.strip.empty?
      email = email.strip

      safe_dir = @config.get('google.safe_dir', '/home/.safe/mail')

      show_feedback("Connecting to Google Calendar...", 226)

      google = Sources::Google.new(email, safe_dir: safe_dir)
      token = google.get_access_token
      unless token
        err = google.last_error || "Check credentials in #{safe_dir}"
        show_feedback("Token failed: #{err}", 196)
        return
      end

      calendars = google.list_calendars
      if calendars.empty?
        err = google.last_error || "No calendars found"
        show_feedback("#{email}: #{err}", 196)
        return
      end

      # Show calendars and let user pick
      cal_list = calendars.each_with_index.map { |c, i| "#{i + 1}:#{c[:summary]}" }.join("  ")
      blank_bottom(" Found #{calendars.size} calendar(s)".fg(39).b)
      pick = bottom_ask(" Add which? (#{cal_list}, 'all', or ESC): ", "all")
      return cancel_create if pick.nil?

      selected = if pick.strip.downcase == 'all'
        calendars
      else
        indices = pick.strip.split(',').map { |s| s.strip.to_i - 1 }
        indices.filter_map { |i| calendars[i] if i >= 0 && i < calendars.size }
      end

      selected.each do |gcal|
        # Check if already added
        existing = @db.get_calendars(false).find { |c|
          config = c['source_config']
          config = JSON.parse(config) if config.is_a?(String)
          config.is_a?(Hash) && config['google_calendar_id'] == gcal[:id]
        }
        next if existing

        @db.save_calendar(
          name: gcal[:summary],
          source_type: 'google',
          source_config: { 'email' => email, 'safe_dir' => safe_dir, 'google_calendar_id' => gcal[:id] },
          color: google_color_to_256(gcal[:color]),
          enabled: true
        )
      end

      # Start sync immediately
      manual_sync
      show_feedback("Added #{selected.size} Google calendar(s). Syncing...", 156)
    end

    def google_color_to_256(hex_color)
      return 39 unless hex_color
      case hex_color&.downcase
      when '#7986cb', '#4285f4' then 69   # blue
      when '#33b679', '#0b8043' then 35   # green
      when '#8e24aa', '#9e69af' then 134  # purple
      when '#e67c73', '#d50000' then 167  # red
      when '#f6bf26', '#f4511e' then 214  # yellow/orange
      when '#039be5', '#4fc3f7' then 39   # cyan
      when '#616161', '#a79b8e' then 245  # gray
      else 39
      end
    end

    def manual_sync
      show_feedback("Syncing calendars...", 226)
      calendars = @db.get_calendars.select { |c| c['source_type'] == 'google' }

      if calendars.empty?
        show_feedback("No Google calendars configured. Press G to set up.", 245)
        return
      end

      total = 0
      errors = []
      calendars.each do |cal|
        config = cal['source_config']
        config = JSON.parse(config) if config.is_a?(String)
        next unless config.is_a?(Hash)

        google = Sources::Google.new(config['email'], safe_dir: config['safe_dir'] || '/home/.safe/mail')
        unless google.get_access_token
          errors << "#{cal['name']}: #{google.last_error || 'token failed'}"
          next
        end

        gcal_id = config['google_calendar_id'] || config['email']
        now = Time.now
        events = google.fetch_events(gcal_id, (now - 90 * 86400).to_i, (now + 90 * 86400).to_i)
        unless events
          errors << "#{cal['name']}: #{google.last_error || 'fetch failed'}"
          next
        end

        events.each do |evt|
          existing = @db.find_event_by_external_id(cal['id'], evt[:external_id])
          if existing
            @db.save_event(id: existing['id'], calendar_id: cal['id'], **evt)
          elsif @db.event_duplicate?(evt[:title], evt[:start_time])
            # Already imported via ICS; skip but don't count as new
          else
            @db.save_event(calendar_id: cal['id'], **evt)
            total += 1
          end
        end
        @db.db.execute("UPDATE calendars SET last_synced_at = ? WHERE id = ?", [Time.now.to_i, cal['id']])
      end

      load_events_for_range
      render_all
      if errors.any?
        show_feedback("Sync: #{total} new. Errors: #{errors.join('; ')}", 196)
      else
        show_feedback("Sync complete. #{total} new event(s).", 156)
      end
    end

    # --- Feedback ---

    def show_feedback(message, color = 156)
      lines = [("-" * @w).fg(238), " #{message}".fg(color)]
      while lines.length < @panes[:bottom].h
        lines << ""
      end
      @panes[:bottom].text = lines.join("\n")
      @panes[:bottom].full_refresh
    end

    # --- Preferences ---

    def pick_color(current = 39)
      rows, cols = IO.console.winsize
      # 16 columns x 16 rows = 256 colors, plus border and labels
      pw = 52  # 16 * 3 + 4
      ph = 20  # 16 rows + header + footer + borders
      px = (cols - pw) / 2
      py = (rows - ph) / 2

      popup = Rcurses::Pane.new(px, py, pw, ph, 252, 0)
      popup.border = true
      popup.scroll = false

      sel = current.to_i.clamp(0, 255)

      build = -> {
        popup.full_refresh
        lines = []
        lines << ""
        lines << "  " + "Pick Color".b + "  current: " + "\u2588\u2588".fg(sel) + " #{sel}"
        lines << ""
        16.times do |row|
          line = " "
          16.times do |col|
            c = row * 16 + col
            if c == sel
              line += "X ".bg(c).fg(255).b
            else
              line += "  ".bg(c)
            end
            line += " "
          end
          lines << line
        end
        lines << ""
        lines << "  " + "Arrows:move  ENTER:select  ESC:cancel".fg(245)
        popup.text = lines.join("\n")
        popup.ix = 0
        popup.refresh
      }

      build.call

      result = nil
      loop do
        k = getchr
        case k
        when 'ESC', 'q'
          break
        when 'ENTER'
          result = sel
          break
        when 'RIGHT', 'l'
          sel = (sel + 1) % 256
          build.call
        when 'LEFT', 'h'
          sel = (sel - 1) % 256
          build.call
        when 'DOWN', 'j'
          sel = (sel + 16) % 256
          build.call
        when 'UP', 'k'
          sel = (sel - 16) % 256
          build.call
        end
      end

      # Clear picker overlay
      Rcurses.clear_screen
      create_panes
      render_all
      result
    end

    def show_calendars
      rows, cols = IO.console.winsize
      pw = [cols - 16, 64].min
      pw = [pw, 50].max

      calendars = @db.get_calendars(false)
      return show_feedback("No calendars configured", 245) if calendars.empty?

      ph = [calendars.size + 7, rows - 6].min
      px = (cols - pw) / 2
      py = (rows - ph) / 2

      popup = Rcurses::Pane.new(px, py, pw, ph, 252, 0)
      popup.border = true
      popup.scroll = false

      sel = 0

      build = -> {
        popup.full_refresh
        lines = []
        lines << ""
        lines << "  " + "Calendars".b
        lines << "  " + ("-" * [pw - 6, 1].max).fg(238)

        calendars.each_with_index do |cal, i|
          enabled = cal['enabled'].to_i == 1
          color = cal['color'] || 39
          swatch = "\u2588\u2588".fg(color)
          status = enabled ? "on".fg(35) : "off".fg(196)
          src = cal['source_type'] || 'local'
          name = cal['name'] || '(unnamed)'
          display = "  #{swatch} %-22s %s  [%s]" % [name[0..21], status, src]
          lines << (i == sel ? display.fg(39).b : display)
        end

        lines << ""
        lines << "  " + "j/k:nav  c:color  ENTER:toggle  x:remove  q:close".fg(245)
        popup.text = lines.join("\n")
        popup.ix = 0
        popup.refresh
      }

      build.call

      loop do
        k = getchr
        case k
        when 'ESC', 'q'
          break
        when 'k', 'UP'
          sel = (sel - 1) % calendars.size
          build.call
        when 'j', 'DOWN'
          sel = (sel + 1) % calendars.size
          build.call
        when 'c'
          cal = calendars[sel]
          new_color = pick_color(cal['color'] || 39)
          if new_color
            @db.execute("UPDATE calendars SET color = ? WHERE id = ?", [new_color, cal['id']])
            cal['color'] = new_color
          end
          build.call
        when 'ENTER'
          cal = calendars[sel]
          new_enabled = cal['enabled'].to_i == 1 ? 0 : 1
          @db.execute("UPDATE calendars SET enabled = ? WHERE id = ?", [new_enabled, cal['id']])
          cal['enabled'] = new_enabled
          build.call
        when 'x'
          cal = calendars[sel]
          confirm = popup.ask(" Remove '#{cal['name']}'? (y/n): ", "")
          if confirm&.strip&.downcase == 'y'
            @db.execute("DELETE FROM events WHERE calendar_id = ?", [cal['id']])
            @db.execute("DELETE FROM calendars WHERE id = ?", [cal['id']])
            calendars.delete_at(sel)
            sel = [sel, calendars.size - 1].min
            break if calendars.empty?
          end
          build.call
        end
      end

      Rcurses.clear_screen
      create_panes
      load_events_for_range
      render_all
    end

    def show_preferences
      rows, cols = IO.console.winsize
      pw = [cols - 20, 56].min
      pw = [pw, 48].max
      ph = 19
      px = (cols - pw) / 2
      py = (rows - ph) / 2

      popup = Rcurses::Pane.new(px, py, pw, ph, 252, 0)
      popup.border = true
      popup.scroll = false

      pref_keys = [
        ['colors.selected_bg_a',  'Sel. alt bg A',    235],
        ['colors.selected_bg_b',  'Sel. alt bg B',    234],
        ['colors.alt_bg_a',       'Row alt bg A',     233],
        ['colors.alt_bg_b',       'Row alt bg B',     0],
        ['colors.current_month_bg','Current month bg', 233],
        ['colors.saturday',       'Saturday color',   208],
        ['colors.sunday',         'Sunday color',     167],
        ['colors.today',          'Today color',      255],
        ['colors.today_bg',       'Today bg',         236],
        ['colors.slot_selected_bg','Slot selected bg',  237],
        ['colors.info_bg',        'Info bar bg',      235],
        ['colors.status_bg',      'Status bar bg',    235],
        ['work_hours.start',      'Work hours start', 8],
        ['work_hours.end',        'Work hours end',   17],
        ['default_calendar',      'Default calendar', 1]
      ]

      sel = 0

      is_color = ->(key) { key.start_with?('colors.') }

      build_popup = -> {
        popup.full_refresh
        inner_w = pw - 4
        lines = []
        lines << ""
        lines << "  " + "Preferences".b
        lines << "  " + ("\u2500" * [inner_w - 3, 1].max).fg(238)

        pref_keys.each_with_index do |(key, label, default), i|
          val = @config.get(key, default)
          if is_color.call(key)
            swatch = key.include?('bg') ? "  ".bg(val.to_i) : "\u2588\u2588".fg(val.to_i)
            val_str = val.to_s.rjust(3)
            display = "  %-18s %s %s" % [label, val_str, swatch]
          else
            display = "  %-18s %s" % [label, val.to_s]
          end
          if i == sel
            lines << display.fg(39).b
          else
            lines << display
          end
        end

        lines << ""
        if is_color.call(pref_keys[sel][0])
          lines << "  " + "j/k:navigate  h/l:adjust  H/L:x10  ENTER:type  q:close".fg(245)
        else
          lines << "  " + "j/k:navigate  ENTER:edit  q/ESC:close".fg(245)
        end

        popup.text = lines.join("\n")
        popup.ix = 0
        popup.refresh
      }

      build_popup.call

      loop do
        k = getchr
        case k
        when 'ESC', 'q'
          break
        when 'k', 'UP'
          sel = (sel - 1) % pref_keys.length
          build_popup.call
        when 'j', 'DOWN'
          sel = (sel + 1) % pref_keys.length
          build_popup.call
        when 'h', 'LEFT'
          key, label, default = pref_keys[sel]
          if is_color.call(key)
            val = [(@config.get(key, default).to_i - 1), 0].max
            @config.set(key, val)
            @config.save
            build_popup.call
          end
        when 'l', 'RIGHT'
          key, label, default = pref_keys[sel]
          if is_color.call(key)
            val = [(@config.get(key, default).to_i + 1), 255].min
            @config.set(key, val)
            @config.save
            build_popup.call
          end
        when 'H'
          key, label, default = pref_keys[sel]
          if is_color.call(key)
            val = [(@config.get(key, default).to_i - 10), 0].max
            @config.set(key, val)
            @config.save
            build_popup.call
          end
        when 'L'
          key, label, default = pref_keys[sel]
          if is_color.call(key)
            val = [(@config.get(key, default).to_i + 10), 255].min
            @config.set(key, val)
            @config.save
            build_popup.call
          end
        when 'ENTER'
          key, label, default = pref_keys[sel]
          current = @config.get(key, default)
          if is_color.call(key)
            new_color = pick_color(current.to_i)
            if new_color
              @config.set(key, new_color)
              @config.save
            end
          else
            result = popup.ask("#{label}: ", current.to_s)
            if result && !result.strip.empty?
              val = result.strip
              val = val.to_i if current.is_a?(Integer)
              @config.set(key, val)
              @config.save
            end
          end
          build_popup.call
        end
      end

      # Re-create panes to apply bar color changes
      Rcurses.clear_screen
      create_panes
      render_all
    end

    # --- Help ---

    def show_help
      rows, cols = IO.console.winsize
      pw = [cols - 16, 68].min
      pw = [pw, 56].max
      ph = 22
      px = (cols - pw) / 2
      py = (rows - ph) / 2

      popup = Rcurses::Pane.new(px, py, pw, ph, 252, 0)
      popup.border = true
      popup.scroll = false

      k = ->(s) { s.fg(51) }      # key color
      d = ->(s) { s.fg(252) }     # description color
      sep = "  " + ("-" * [pw - 6, 1].max).fg(238)

      help = []
      help << ""
      help << "  " + "Timely - Terminal Calendar".b.fg(156)
      help << sep
      help << "  " + "Navigation".b.fg(156)
      help << "  #{k['d/RIGHT']}  #{d['Next day']}        #{k['D/LEFT']}  #{d['Prev day']}"
      help << "  #{k['w']}        #{d['Next week']}       #{k['W']}       #{d['Prev week']}"
      help << "  #{k['m']}        #{d['Next month']}      #{k['M']}       #{d['Prev month']}"
      help << "  #{k['y']}        #{d['Next year']}       #{k['Y']}       #{d['Prev year']}"
      help << "  #{k['UP/DOWN']}  #{d['Select time slot (scrolls at edges)']}"
      help << "  #{k['PgUp/Dn']}  #{d['Jump 10 slots']}   #{k['HOME']}    #{d['Top/all-day']}"
      help << "  #{k['END']}      #{d['Bottom (23:30)']}  #{k['j/k']}     #{d['Cycle events']}"
      help << "  #{k['e/E']}      #{d['Jump to event (next/prev)']}"
      help << "  #{k['t']}        #{d['Today']}           #{k['g']}       #{d['Go to (date, Mon, yyyy)']}"
      help << sep
      help << "  " + "Events".b.fg(156)
      help << "  #{k['n']}        #{d['New event']}       #{k['ENTER']}   #{d['Edit event']}"
      help << "  #{k['x/DEL']}    #{d['Delete event']}    #{k['a']}       #{d['Accept invite']}"
      help << "  #{k['r']}        #{d['Reply via Heathrow']}"
      help << sep
      help << "  #{k['i']}  #{d['Import ICS']}   #{k['G']}  #{d['Google setup']}   #{k['S']}  #{d['Sync now']}"
      help << "  #{k['C']}  #{d['Calendars']}    #{k['P']}  #{d['Preferences']}    #{k['q']}  #{d['Quit']}"
      help << ""
      help << "  " + "Press any key to close...".fg(245)

      popup.text = help.join("\n")
      popup.refresh
      getchr
      Rcurses.clear_screen
      create_panes
      render_all
    end
  end
end
