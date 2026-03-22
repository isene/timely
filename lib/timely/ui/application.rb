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
      @current_view = :month
      @selected_date = Date.today
      @selected_hour = @config.get('work_hours.start', 8)
      @width = 4  # Left pane width ratio (out of 10)
      @border = 1
      @events_cache = {}
      @work_start = @config.get('work_hours.start', 8)
      @work_end = @config.get('work_hours.end', 17)
    end

    def run
      Rcurses.init!
      Rcurses.clear_screen

      setup_display
      create_panes

      load_events
      render_all

      # Flush stdin before loop
      $stdin.getc while $stdin.wait_readable(0)

      @running = true
      loop do
        chr = getchr(2, flush: false)
        if chr
          handle_input_key(chr)
        end
        break unless @running
      end
    ensure
      Cursor.show
    end

    private

    def handle_input_key(chr)
      case chr
      # Navigation
      when 'h', 'LEFT'
        navigate_left
      when 'l', 'RIGHT'
        navigate_right
      when 'j', 'DOWN'
        navigate_down
      when 'k', 'UP'
        navigate_up
      when 'PgDOWN'
        navigate_page_down
      when 'PgUP'
        navigate_page_up

      # View switching
      when '1'
        switch_view(:year)
      when '2'
        switch_view(:quarter)
      when '3'
        switch_view(:month)
      when '4'
        switch_view(:week)
      when '5'
        switch_view(:workweek)
      when '6'
        switch_view(:day)

      # Actions
      when 'T'
        @selected_date = Date.today
        @selected_hour = @work_start
        load_events
        render_all
      when 'g'
        go_to_date
      when 'n'
        show_feedback("Event creation not yet implemented", 226)
      when 'ENTER'
        # Switch to day view for selected date
        switch_view(:day)

      # UI
      when 'w'
        @width = (@width % 8) + 1
        setup_display
        create_panes
        render_all
      when 'B'
        @border = (@border + 1) % 4
        set_borders
        render_all
      when 'r'
        load_events
        render_all
      when '?'
        show_help
      when 'q'
        @running = false
      end
    end

    # Navigation methods

    def navigate_left
      case @current_view
      when :year
        @selected_date = @selected_date << 1  # Previous month
      when :quarter
        @selected_date = @selected_date << 1
      when :month
        @selected_date = @selected_date - 1  # Previous day
      when :week, :workweek
        @selected_date = @selected_date - 1
      when :day
        @selected_date = @selected_date - 1
      end
      load_events
      render_all
    end

    def navigate_right
      case @current_view
      when :year
        @selected_date = @selected_date >> 1  # Next month
      when :quarter
        @selected_date = @selected_date >> 1
      when :month
        @selected_date = @selected_date + 1  # Next day
      when :week, :workweek
        @selected_date = @selected_date + 1
      when :day
        @selected_date = @selected_date + 1
      end
      load_events
      render_all
    end

    def navigate_down
      case @current_view
      when :year
        @selected_date = @selected_date >> 3  # Skip 3 months (next row)
      when :quarter
        @selected_date = @selected_date + 7
      when :month
        @selected_date = @selected_date + 7  # Next week
      when :week, :workweek
        @selected_hour = [@selected_hour + 1, 23].min
      when :day
        @selected_hour = [@selected_hour + 1, 23].min
      end
      load_events
      render_all
    end

    def navigate_up
      case @current_view
      when :year
        @selected_date = @selected_date << 3  # Skip 3 months back (prev row)
      when :quarter
        @selected_date = @selected_date - 7
      when :month
        @selected_date = @selected_date - 7  # Previous week
      when :week, :workweek
        @selected_hour = [@selected_hour - 1, 0].max
      when :day
        @selected_hour = [@selected_hour - 1, 0].max
      end
      load_events
      render_all
    end

    def navigate_page_down
      case @current_view
      when :year
        @selected_date = Date.new(@selected_date.year + 1, @selected_date.month, @selected_date.day)
      when :month
        @selected_date = @selected_date >> 1  # Next month
      when :week, :workweek
        @selected_date = @selected_date + 7
      when :day
        @selected_date = @selected_date + 7
      end
      load_events
      render_all
    end

    def navigate_page_up
      case @current_view
      when :year
        @selected_date = Date.new(@selected_date.year - 1, @selected_date.month, @selected_date.day)
      when :month
        @selected_date = @selected_date << 1  # Previous month
      when :week, :workweek
        @selected_date = @selected_date - 7
      when :day
        @selected_date = @selected_date - 7
      end
      load_events
      render_all
    end

    def switch_view(view)
      @current_view = view
      load_events
      render_all
    end

    # Data loading

    def load_events
      range = visible_date_range
      start_ts = Time.new(range[:start].year, range[:start].month, range[:start].day, 0, 0, 0).to_i
      end_ts = Time.new(range[:end].year, range[:end].month, range[:end].day, 23, 59, 59).to_i

      raw_events = @db.get_events_in_range(start_ts, end_ts)

      # Build events_by_date hash
      @events_by_date = {}
      raw_events.each do |evt|
        st = Time.at(evt['start_time'].to_i).to_date
        et = evt['end_time'] ? Time.at(evt['end_time'].to_i).to_date : st

        (st..et).each do |d|
          next unless d >= range[:start] && d <= range[:end]
          @events_by_date[d] ||= []
          @events_by_date[d] << evt
        end
      end
    end

    def visible_date_range
      case @current_view
      when :year
        { start: Date.new(@selected_date.year, 1, 1),
          end: Date.new(@selected_date.year, 12, 31) }
      when :quarter
        q_start = ((@selected_date.month - 1) / 3) * 3 + 1
        { start: Date.new(@selected_date.year, q_start, 1),
          end: Date.new(@selected_date.year, q_start + 2, -1) }
      when :month
        { start: Date.new(@selected_date.year, @selected_date.month, 1),
          end: Date.new(@selected_date.year, @selected_date.month, -1) }
      when :week
        week_start = @selected_date - (@selected_date.cwday - 1)
        { start: week_start, end: week_start + 6 }
      when :workweek
        week_start = @selected_date - (@selected_date.cwday - 1)
        { start: week_start, end: week_start + 4 }
      when :day
        { start: @selected_date, end: @selected_date }
      else
        { start: Date.new(@selected_date.year, @selected_date.month, 1),
          end: Date.new(@selected_date.year, @selected_date.month, -1) }
      end
    end

    # Rendering

    def render_all
      # Check for terminal resize
      old_h, old_w = @h, @w
      setup_display
      if @h != old_h || @w != old_w
        Rcurses.clear_screen
        create_panes
      end

      render_top_bar
      render_left_pane
      render_right_pane
      render_bottom_bar
    end

    def render_left_pane
      content = case @current_view
                when :year
                  UI::Views::Year.render_year(
                    @selected_date.year,
                    @selected_date.month,
                    @selected_date.day,
                    @events_by_date || {},
                    @panes[:left].w,
                    @panes[:left].h
                  )
                when :month, :quarter
                  UI::Views::Month.render_month(
                    @selected_date.year,
                    @selected_date.month,
                    @selected_date.day,
                    @events_by_date || {},
                    @panes[:left].w,
                    @panes[:left].h
                  )
                when :week
                  week_start = @selected_date - (@selected_date.cwday - 1)
                  UI::Views::Week.render_week(
                    week_start,
                    nil,
                    @events_by_date || {},
                    @panes[:left].w,
                    @panes[:left].h,
                    work_start: @work_start,
                    work_end: @work_end
                  )
                when :workweek
                  week_start = @selected_date - (@selected_date.cwday - 1)
                  UI::Views::Week.render_week(
                    week_start,
                    nil,
                    @events_by_date || {},
                    @panes[:left].w,
                    @panes[:left].h,
                    work_start: @work_start,
                    work_end: @work_end,
                    workweek: true
                  )
                when :day
                  events = (@events_by_date || {})[@selected_date] || []
                  UI::Views::Day.render_day(
                    @selected_date,
                    @selected_hour,
                    events,
                    @panes[:left].w,
                    @panes[:left].h,
                    work_start: @work_start,
                    work_end: @work_end
                  )
                else
                  "Unknown view: #{@current_view}"
                end

      @panes[:left].text = content
      @panes[:left].refresh
    end

    def render_right_pane
      lines = []
      events = (@events_by_date || {})[@selected_date] || []

      # Date header
      lines << @selected_date.strftime("  %A, %B %d").b
      lines << ""

      # Moon phase
      phase = Astronomy.moon_phase(@selected_date)
      lines << "  #{phase[:symbol]} #{phase[:phase_name]}"
      lines << "  Illumination: #{(phase[:illumination] * 100).round}%"
      lines << ""

      if events.empty?
        lines << "  No events".fg(245)
      else
        lines << "  Events:".b
        lines << ""
        events.each do |evt|
          color = evt['calendar_color'] || 39

          # Time
          if evt['all_day'].to_i == 1
            time_str = "  All day"
          else
            st = Time.at(evt['start_time'].to_i)
            time_str = "  #{st.strftime('%H:%M')}"
            if evt['end_time']
              et = Time.at(evt['end_time'].to_i)
              time_str += " - #{et.strftime('%H:%M')}"
            end
          end

          lines << time_str.fg(245)
          lines << "  #{evt['title']}".fg(color).b

          if evt['location'] && !evt['location'].to_s.empty?
            lines << "  @ #{evt['location']}".fg(245)
          end

          if evt['description'] && !evt['description'].to_s.empty?
            desc = evt['description'].to_s.slice(0, @panes[:right].w - 6)
            lines << "  #{desc}".fg(248)
          end

          cal_name = evt['calendar_name'] || 'Unknown'
          lines << "  [#{cal_name}]".fg(240)
          lines << ""
        end
      end

      @panes[:right].text = lines.join("\n")
      @panes[:right].refresh
    end

    # Actions

    def go_to_date
      input = @panes[:bottom].ask("Go to date (YYYY-MM-DD): ", "")
      return if input.nil? || input.strip.empty?

      begin
        @selected_date = Date.parse(input.strip)
        load_events
        render_all
      rescue Date::Error
        show_feedback("Invalid date format", 196)
      end
    end

    def show_feedback(message, color = 156)
      @panes[:bottom].text = " #{message}".fg(color)
      @panes[:bottom].refresh
    end

    def show_help
      help = []
      help << "Timely - Terminal Calendar".b
      help << ""
      help << "Navigation:".b
      help << "  h/LEFT    Previous day/month"
      help << "  l/RIGHT   Next day/month"
      help << "  j/DOWN    Next week/hour"
      help << "  k/UP      Previous week/hour"
      help << "  PgDn      Next month/year"
      help << "  PgUp      Previous month/year"
      help << ""
      help << "Views:".b
      help << "  1         Year view"
      help << "  2         Quarter view"
      help << "  3         Month view"
      help << "  4         Week view"
      help << "  5         Work week view"
      help << "  6         Day view"
      help << "  Enter     Day view for selected"
      help << ""
      help << "Actions:".b
      help << "  T         Go to today"
      help << "  g         Go to date"
      help << "  n         New event"
      help << "  r         Refresh"
      help << ""
      help << "UI:".b
      help << "  w         Cycle pane width"
      help << "  B         Toggle border"
      help << "  ?         This help"
      help << "  q         Quit"
      help << ""
      help << "Press any key to close..."

      @panes[:right].text = help.join("\n")
      @panes[:right].refresh
      getchr
      render_all
    end
  end
end
