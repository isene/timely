module Timely
  module UI
    module Views
      module Month
        WEEKDAYS = %w[Mo Tu We Th Fr Sa Su].freeze
        MINI_WIDTH = 25  # 3 extra for "WW " week number prefix

        # Render a compact mini-month calendar.
        # Returns an array of strings (one per line), about 8-9 lines tall.
        # selected_day: day number to highlight with reverse video (or nil)
        # today: Date.today for bold+underline marking
        # events_by_date: hash of Date => [event_hashes] for coloring event days
        # width: available width (typically 22 chars)
        def self.render_mini_month(year, month, selected_day, today, events_by_date, width = MINI_WIDTH, today_bg: 254)
          lines = []

          # Title: centered month and year
          title = Date.new(year, month, 1).strftime("%B %Y")
          pad = [(width - title.length) / 2, 1].max
          lines << (" " * pad + title).b

          # Weekday headers (with space for week number column)
          header = "    " + WEEKDAYS.each_with_index.map { |d, i|
            s = d.rjust(2)
            case i
            when 5 then s.fg(208)  # Saturday
            when 6 then s.fg(167)  # Sunday
            else s.fg(245)
            end
          }.join(" ")
          lines << header

          # Build calendar grid
          first_day = Date.new(year, month, 1)
          last_day = Date.new(year, month, -1)
          start_offset = first_day.cwday - 1

          week = []
          start_offset.times { week << nil }

          (1..last_day.day).each do |day|
            week << day
            if week.length == 7
              lines << format_week(week, year, month, today, selected_day, events_by_date, today_bg)
              week = []
            end
          end

          # Final partial week
          unless week.empty?
            week << nil while week.length < 7
            lines << format_week(week, year, month, today, selected_day, events_by_date, today_bg)
          end

          # Pad to consistent height (title + header + 6 week rows = 8 lines)
          while lines.length < 8
            lines << " " * width
          end

          lines
        end

        private

        def self.format_week(week, year, month, today, selected_day, events_by_date, today_bg = 236)
          # Find week number from first non-nil day in this row
          first_day = week.compact.first
          wn = first_day ? Date.new(year, month, first_day).cweek.to_s.rjust(2) : "  "

          cells = week.map do |day|
            if day.nil?
              "  "
            else
              format_day(day, year, month, today, selected_day, events_by_date, today_bg)
            end
          end
          wn.fg(238) + " " + cells.join(" ")
        end

        def self.format_day(day, year, month, today, selected_day, events_by_date, today_bg = 236)
          date = Date.new(year, month, day)
          events = events_by_date[date]

          is_today = (date == today)
          is_selected = (selected_day && day == selected_day && date.month == today.month && date.year == today.year) ||
                        (selected_day && day == selected_day)

          # selected_day is only meaningful when this is the selected month
          # The caller controls which month gets a non-nil selected_day

          # Base fg color: event > sunday > saturday > default
          base_color = if events && !events.empty?
            events.first['calendar_color'] || 39
          elsif date.sunday?
            167
          elsif date.saturday?
            208
          else
            nil
          end

          d = day.to_s.rjust(2)
          if is_selected && is_today
            base_color ? d.b.u.fg(base_color).bg(today_bg) : d.b.u.bg(today_bg)
          elsif is_selected
            base_color ? d.b.u.fg(base_color) : d.b.u
          elsif is_today
            base_color ? d.fg(base_color).bg(today_bg) : d.bg(today_bg)
          elsif base_color
            d.fg(base_color)
          else
            d
          end
        end
      end
    end
  end
end
