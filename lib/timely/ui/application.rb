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
      render_all

      # Flush stdin before loop
      $stdin.getc while $stdin.wait_readable(0)

      @running = true
      loop do
        chr = getchr(2, flush: false)
        handle_input(chr) if chr
        break unless @running
      end
    ensure
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
      when 'P'
        show_preferences
      when '?'
        show_help
      when 'q'
        @running = false
      end
    end

    # --- Time slot navigation ---

    def move_slot_down
      work_start = @config.get('work_hours.start', 8) rescue 8
      @selected_slot ||= work_start * 2
      @selected_slot = @selected_slot >= 47 ? 0 : @selected_slot + 1
      available_rows = @panes[:mid].h - 3
      if @selected_slot == 0
        @slot_offset = 0
      elsif @selected_slot - @slot_offset >= available_rows
        @slot_offset = @selected_slot - available_rows + 1
      end
      render_mid_pane
      render_bottom_pane
    end

    def move_slot_up
      work_start = @config.get('work_hours.start', 8) rescue 8
      @selected_slot ||= work_start * 2
      @selected_slot = @selected_slot <= 0 ? 47 : @selected_slot - 1
      available_rows = @panes[:mid].h - 3
      if @selected_slot == 47
        @slot_offset = [48 - available_rows, 0].max
      elsif @selected_slot < @slot_offset
        @slot_offset = @selected_slot
      end
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
      keys = "d/D:Day  w/W:Week  m/M:Month  y/Y:Year  e/E:Event  n:New  g:GoTo  t:Today  P:Prefs  ?:Help  q:Quit"
      @panes[:status].text = " " + keys
      @panes[:status].refresh
    end

    # Top pane: horizontal strip of mini-month calendars
    def render_top_pane
      today = Date.today
      month_width = 23
      months_visible = [@w / month_width, 1].max

      offset = months_visible / 2

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
        lines = UI::Views::Month.render_mini_month(year, month, sel_day, today, @events_by_date, month_width - 1)
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

      # Column headers: time column + day headers
      header_parts = [" " * time_col]
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

        header = if is_sel
          header.b.u.fg(base_color).bg(sel_bg)
        elsif is_today
          header.b.u.fg(base_color)
        else
          header.fg(base_color)
        end

        pure_len = Rcurses.display_width(header.respond_to?(:pure) ? header.pure : header)
        pad = [day_col - pure_len, 0].max
        padding = is_sel ? " ".bg(sel_bg) * pad : " " * pad
        header_parts << header + padding
      end
      lines << header_parts.join(" ")
      lines << ("\u2500" * @w).fg(238)

      # Gather events for each day
      week_events = []
      7.times do |i|
        day = week_start + i
        week_events << (@events_by_date[day] || []).sort_by { |e| e['start_time'].to_i }
      end

      # Build half-hour time slots with scroll offset
      work_start = @config.get('work_hours.start', 8) rescue 8
      available_rows = @panes[:mid].h - 3  # weather row + header + separator
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
            (es < day_ts_end && ee > day_ts_start) || e['all_day'].to_i == 1
          end

          # Find event index on this day for selection marker
          evt_idx = evt ? week_events[col].index(evt) : nil

          if evt
            marker = (is_sel && evt_idx == @selected_event_index) ? ">" : " "
            title = evt['title'] || "(No title)"
            color = evt['calendar_color'] || 39
            entry = "#{marker}#{title}"
            entry = entry[0, day_col - 1] + "." if entry.length > day_col
            cell = (is_sel && evt_idx == @selected_event_index) ? entry.fg(color).b.bg(cell_bg) : entry.fg(color).bg(cell_bg)
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

      if events.any? && @selected_event_index < events.length
        evt = events[@selected_event_index]
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
      input = @panes[:bottom].ask("Go to: ", "")
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
      title = @panes[:bottom].ask("Event title: ", "")
      return if title.nil? || title.strip.empty?

      default_time = if @selected_slot
        format("%02d:%02d", @selected_slot / 2, (@selected_slot % 2) * 30)
      else
        "09:00"
      end
      time_str = @panes[:bottom].ask("Start time (HH:MM, or 'all day'): ", default_time)
      return if time_str.nil?

      all_day = (time_str.strip.downcase == 'all day')

      if all_day
        start_ts = Time.new(@selected_date.year, @selected_date.month, @selected_date.day, 0, 0, 0).to_i
        end_ts = start_ts + 86400
      else
        parts = time_str.strip.split(':')
        hour = parts[0].to_i
        minute = (parts[1] || 0).to_i
        start_ts = Time.new(@selected_date.year, @selected_date.month, @selected_date.day, hour, minute, 0).to_i

        dur_str = @panes[:bottom].ask("Duration in minutes: ", "60")
        return if dur_str.nil?
        duration = dur_str.strip.to_i
        duration = 60 if duration <= 0
        end_ts = start_ts + duration * 60
      end

      @db.save_event(
        title: title.strip,
        start_time: start_ts,
        end_time: end_ts,
        all_day: all_day,
        calendar_id: 1,
        status: 'confirmed'
      )

      load_events_for_range
      render_all
      show_feedback("Event created: #{title.strip}", 156)
    end

    def edit_event
      events = events_on_selected_day
      return show_feedback("No event to edit", 245) if events.empty?

      evt = events[@selected_event_index]
      return show_feedback("No event selected", 245) unless evt

      new_title = @panes[:bottom].ask("Title: ", evt['title'] || "")
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
      return show_feedback("No event to delete", 245) if events.empty?

      evt = events[@selected_event_index]
      return show_feedback("No event selected", 245) unless evt

      confirm = @panes[:bottom].ask("Delete '#{evt['title']}'? (y/n): ", "")
      return unless confirm&.strip&.downcase == 'y'

      @db.delete_event(evt['id'])
      @selected_event_index = 0

      load_events_for_range
      render_all
      show_feedback("Event deleted", 156)
    end

    def accept_invite
      events = events_on_selected_day
      return show_feedback("No event to accept", 245) if events.empty?

      evt = events[@selected_event_index]
      return show_feedback("No event selected", 245) unless evt

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

      load_events_for_range
      render_all
      show_feedback("Invite accepted", 156)
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
        ['colors.slot_selected_bg','Slot selected bg',  237],
        ['colors.info_bg',        'Info bar bg',      235],
        ['colors.status_bg',      'Status bar bg',    235],
        ['work_hours.start',      'Work hours start', 8],
        ['work_hours.end',        'Work hours end',   17]
      ]

      sel = 0

      build_popup = -> {
        popup.full_refresh
        inner_w = pw - 4
        lines = []
        lines << ""
        lines << "  " + "Preferences".b
        lines << "  " + ("\u2500" * [inner_w - 3, 1].max).fg(238)

        pref_keys.each_with_index do |(key, label, default), i|
          val = @config.get(key, default)
          display = "  %-20s %s" % [label, val.to_s]
          if i == sel
            lines << display.fg(39).b
          else
            lines << display
          end
        end

        lines << ""
        lines << "  " + "j/k:navigate  ENTER:edit  q/ESC:close".fg(245)

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
        when 'ENTER'
          key, label, default = pref_keys[sel]
          current = @config.get(key, default)
          result = popup.ask("#{label}: ", current.to_s)
          if result && !result.strip.empty?
            val = result.strip
            # Convert to integer for numeric settings
            val = val.to_i if current.is_a?(Integer)
            @config.set(key, val)
            @config.save
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
      help = []
      help << " Timely - Terminal Calendar".b
      help << ""
      help << " Navigation:".b
      help << "   d/l/RIGHT  Next day         D/h/LEFT  Previous day"
      help << "   w          Next week         W         Previous week"
      help << "   m          Next month        M         Previous month"
      help << "   y          Next year         Y         Previous year"
      help << "   UP/DOWN    Select time slot   (scrolls at edges)"
      help << "   j          Next event (day)  k         Previous event (day)"
      help << "   e          Next event (any)  E         Previous event (any)"
      help << "   t          Go to today       g         Go to date"
      help << ""
      help << " Events:".b
      help << "   n          New event         ENTER     Edit event"
      help << "   x/DEL      Delete event      a         Accept invite"
      help << "   r          Reply via Heathrow"
      help << ""
      help << " P  Preferences   q  Quit   ?  This help"
      help << ""
      help << " Press any key to close..."

      # Show help in all panes combined (using bottom pane)
      @panes[:bottom].text = help.join("\n")
      @panes[:bottom].full_refresh
      getchr
      render_all
    end
  end
end
