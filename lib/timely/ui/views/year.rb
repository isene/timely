module Timely
  module UI
    module Views
      module Year
        WEEKDAYS_SHORT = %w[M T W T F S S].freeze

        # Render 12 mini-months in a grid for the left pane.
        def self.render_year(year, selected_month, selected_day, events_by_date, pane_width, pane_height)
          lines = []
          today = Date.today

          # Title
          title = year.to_s
          pad = [(pane_width - title.length) / 2, 2].max
          lines << (" " * pad + title).b
          lines << ""

          # Determine columns based on pane width
          mini_width = 22
          cols = [(pane_width - 2) / mini_width, 1].max
          cols = [cols, 4].min  # Max 4 columns

          # Generate all 12 mini-months
          months = (1..12).map { |m| render_mini_month(year, m, today, selected_month, selected_day, events_by_date) }

          # Arrange in rows
          rows = months.each_slice(cols).to_a

          rows.each do |row|
            # Each mini-month is an array of lines; merge them side by side
            max_lines = row.map(&:length).max
            row.each { |m| m << " " * mini_width while m.length < max_lines }

            max_lines.times do |i|
              line = row.map { |m| (m[i] || "").ljust(mini_width) }.join("  ")
              lines << "  " + line
            end
            lines << ""
          end

          lines.join("\n")
        end

        private

        def self.render_mini_month(year, month, today, selected_month, selected_day, events_by_date)
          lines = []

          # Month name header
          name = Date::MONTHNAMES[month]
          if month == selected_month
            lines << name.center(20).b.fg(255).bg(17)
          else
            lines << name.center(20).b
          end

          # Weekday header
          lines << WEEKDAYS_SHORT.map { |d| d.rjust(2) }.join(" ")

          # Build weeks
          first_day = Date.new(year, month, 1)
          last_day = Date.new(year, month, -1)
          start_offset = first_day.cwday - 1

          week = []
          start_offset.times { week << "  " }

          (1..last_day.day).each do |day|
            date = Date.new(year, month, day)
            day_str = day.to_s.rjust(2)

            is_today = (date == today)
            is_selected = (month == selected_month && day == selected_day)
            has_events = events_by_date[date] && !events_by_date[date].empty?

            if is_selected
              day_str = day_str.bg(17).fg(255)
            elsif is_today
              day_str = day_str.b.u
            elsif has_events
              day_str = day_str.fg(39)
            end

            week << day_str

            if week.length == 7
              lines << week.join(" ")
              week = []
            end
          end

          unless week.empty?
            week << "  " while week.length < 7
            lines << week.join(" ")
          end

          lines
        end
      end
    end
  end
end
