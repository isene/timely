module Timely
  module UI
    module Views
      module Day
        # Render a single day view with 30-minute time slots.
        def self.render_day(date, selected_hour, events, pane_width, pane_height, work_start: 8, work_end: 17)
          lines = []
          today = Date.today

          # Day header
          if date == today
            lines << date.strftime("  %A, %B %d, %Y").b.u
          else
            lines << date.strftime("  %A, %B %d, %Y").b
          end
          lines << ""

          # Moon phase
          phase = Timely::Astronomy.moon_phase(date)
          lines << "  #{phase[:symbol]} #{phase[:phase_name]}"
          lines << ""

          # Time slots (30-min intervals)
          slot_width = pane_width - 10

          (0..23).each do |hour|
            [0, 30].each do |minute|
              time_str = format("  %02d:%02d ", hour, minute)
              slot_start = Time.new(date.year, date.month, date.day, hour, minute, 0).to_i
              slot_end = slot_start + 1800

              # Find events in this slot
              matching = events.select do |e|
                e_start = e['start_time'].to_i
                e_end = (e['end_time'] || e_start + 3600).to_i
                e_start < slot_end && e_end > slot_start
              end

              # Highlight if selected
              is_selected = (selected_hour == hour && minute == 0)

              if matching.empty?
                if is_selected
                  line = time_str.bg(17).fg(255) + " " * slot_width
                elsif hour >= work_start && hour < work_end
                  line = time_str.fg(245) + ".".fg(236) * [slot_width, 0].max
                else
                  line = time_str.fg(240)
                end
              else
                evt = matching.first
                title = (evt['title'] || "").slice(0, slot_width - 2)
                color = evt['calendar_color'] || 39
                loc = evt['location']
                display = title
                display += " @ #{loc}" if loc && !loc.empty? && (display.length + loc.length + 3) < slot_width

                if is_selected
                  line = time_str.bg(17).fg(255) + display.ljust(slot_width).fg(color)
                else
                  line = time_str.fg(245) + display.ljust(slot_width).fg(color)
                end
              end

              lines << line
            end
          end

          lines.join("\n")
        end
      end
    end
  end
end
