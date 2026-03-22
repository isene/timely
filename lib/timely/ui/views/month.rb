module Timely
  module UI
    module Views
      module Month
        WEEKDAYS = %w[Mo Tu We Th Fr Sa Su].freeze

        # Render a month calendar into a string for the left pane.
        # events_by_date: hash of Date => Array of event hashes
        def self.render_month(year, month, selected_day, events_by_date, pane_width, pane_height)
          lines = []
          today = Date.today

          # Title: centered month and year
          title = Date.new(year, month, 1).strftime("%B %Y")
          pad = [(pane_width - title.length) / 2, 2].max
          lines << (" " * pad + title).b

          # Blank line after title
          lines << ""

          # Weekday headers
          header = "  " + WEEKDAYS.map { |d| d.rjust(2) }.join(" ")
          lines << header.b

          # Build calendar grid
          first_day = Date.new(year, month, 1)
          last_day = Date.new(year, month, -1)

          # Monday = 1, Sunday = 7 (ISO)
          start_offset = first_day.cwday - 1

          # Build weeks
          week = []
          start_offset.times { week << nil }

          (1..last_day.day).each do |day|
            week << day
            if week.length == 7
              lines << format_week(week, year, month, today, selected_day, events_by_date)
              week = []
            end
          end

          # Final partial week
          unless week.empty?
            week << nil while week.length < 7
            lines << format_week(week, year, month, today, selected_day, events_by_date)
          end

          # Moon phase info for selected day (below calendar)
          lines << ""
          sel_date = Date.new(year, month, selected_day) rescue nil
          if sel_date
            phase = Astronomy.moon_phase(sel_date)
            lines << "  #{phase[:symbol]} #{phase[:phase_name]} (#{(phase[:illumination] * 100).round}%)"
          end

          # Notable moon phases this month
          notable = Astronomy.notable_phases_in_month(year, month)
          unless notable.empty?
            lines << ""
            lines << "  Moon phases:".fg(245)
            notable.each do |n|
              lines << "  #{n[:day].to_s.rjust(2)}: #{n[:symbol]} #{n[:phase_name]}".fg(245)
            end
          end

          lines.join("\n")
        end

        private

        def self.format_week(week, year, month, today, selected_day, events_by_date)
          cells = week.map do |day|
            if day.nil?
              "  "
            else
              format_day(day, year, month, today, selected_day, events_by_date)
            end
          end
          "  " + cells.join(" ")
        end

        def self.format_day(day, year, month, today, selected_day, events_by_date)
          date = Date.new(year, month, day)
          events = events_by_date[date]

          is_today = (date == today)
          is_selected = (day == selected_day)

          if is_selected && is_today
            day.to_s.rjust(2).b.u.r
          elsif is_selected
            day.to_s.rjust(2).r
          elsif is_today
            day.to_s.rjust(2).b.u
          elsif events && !events.empty?
            color = events.first['calendar_color'] || 39
            day.to_s.rjust(2).fg(color)
          else
            day.to_s.rjust(2)
          end
        end
      end
    end
  end
end
