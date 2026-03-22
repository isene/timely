module Timely
  module UI
    module Views
      module Week
        DAYS = %w[Mon Tue Wed Thu Fri Sat Sun].freeze

        # Render a week view with hourly rows and day columns.
        # start_date should be the Monday of the week.
        def self.render_week(start_date, selected_time, events_by_date, pane_width, pane_height, work_start: 8, work_end: 17, workweek: false)
          lines = []
          today = Date.today

          num_days = workweek ? 5 : 7
          day_names = workweek ? DAYS[0..4] : DAYS

          # Calculate column width
          time_col = 6  # "HH:MM "
          remaining = pane_width - time_col - 2
          col_width = [remaining / num_days, 3].max

          # Header with day names and dates
          header = " " * time_col
          dates_line = " " * time_col

          num_days.times do |i|
            date = start_date + i
            name = day_names[i]
            date_str = date.strftime("%d")

            if date == today
              cell = "#{name} #{date_str}".center(col_width).b.u
            elsif date == (selected_time ? Date.new(selected_time[:year], selected_time[:month], selected_time[:day]) : nil)
              cell = "#{name} #{date_str}".center(col_width).bg(17).fg(255)
            else
              cell = "#{name} #{date_str}".center(col_width)
            end
            header += cell
          end

          lines << header
          lines << "-" * [pane_width - 2, 1].max

          # Hour rows
          (work_start..work_end).each do |hour|
            time_str = format("%02d:00 ", hour)
            row = time_str.fg(245)

            num_days.times do |i|
              date = start_date + i
              events = events_by_date[date] || []

              # Find events that overlap this hour
              hour_start = Time.new(date.year, date.month, date.day, hour, 0, 0).to_i
              hour_end = hour_start + 3600

              matching = events.select do |e|
                e_start = e['start_time'].to_i
                e_end = (e['end_time'] || e_start + 3600).to_i
                e_start < hour_end && e_end > hour_start
              end

              if matching.empty?
                row += " " * col_width
              else
                evt = matching.first
                title = (evt['title'] || "").slice(0, col_width - 1)
                color = evt['calendar_color'] || 39
                row += title.ljust(col_width).fg(color)
              end
            end

            lines << row
          end

          lines.join("\n")
        end
      end
    end
  end
end
