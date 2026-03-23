module Timely
  module Notifications
    # Check for upcoming events and send desktop notifications.
    # alarm_minutes: how many minutes before event to notify.
    def self.check_and_notify(db, default_alarm: 15)
      now = Time.now.to_i
      # Check events starting within the next hour
      upcoming = db.get_events_in_range(now, now + 3600)

      # Ensure notification_log table exists
      ensure_notification_table(db)

      upcoming.each do |evt|
        next if evt['all_day'].to_i == 1

        start_ts = evt['start_time'].to_i
        minutes_until = (start_ts - now) / 60

        # Get alarm offsets (default to configured alarm if not set)
        alarms = evt['alarms']
        alarms = JSON.parse(alarms) if alarms.is_a?(String)
        alarm_offsets = alarms.is_a?(Array) ? alarms : [default_alarm]

        alarm_offsets.each do |offset|
          offset = offset.to_i
          # Trigger if we are within 1 minute of the alarm time
          next unless minutes_until >= offset - 1 && minutes_until <= offset + 1

          # Check if we already notified for this alarm
          notified = db.db.get_first_value(
            "SELECT COUNT(*) FROM notification_log WHERE event_id = ? AND alarm_offset = ?",
            [evt['id'], offset]
          ).to_i > 0

          unless notified
            send_notification(evt, minutes_until)
            db.db.execute(
              "INSERT OR REPLACE INTO notification_log (event_id, alarm_offset, notified_at) VALUES (?, ?, ?)",
              [evt['id'], offset, now]
            )
          end
        end
      end
    rescue => e
      # Never crash on notification errors
      nil
    end

    def self.send_notification(evt, minutes_until)
      title = evt['title'] || '(No title)'
      time_str = Time.at(evt['start_time'].to_i).strftime('%H:%M')
      body = if minutes_until <= 1
        "Starting now (#{time_str})"
      else
        "In #{minutes_until.to_i} minutes (#{time_str})"
      end
      loc = evt['location']
      body += "\n#{loc}" if loc && !loc.to_s.empty?

      system("notify-send", "-a", "Timely", "-u", "normal", "-i", "calendar", title, body)
    rescue => e
      nil
    end

    # Create the notification_log table if it does not exist.
    def self.ensure_notification_table(db)
      return if @notification_table_created
      db.db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS notification_log (
          event_id INTEGER NOT NULL,
          alarm_offset INTEGER NOT NULL,
          notified_at INTEGER NOT NULL,
          PRIMARY KEY(event_id, alarm_offset)
        )
      SQL
      # Clean old entries (older than 24 hours)
      db.db.execute("DELETE FROM notification_log WHERE notified_at < ?", [Time.now.to_i - 86400])
      @notification_table_created = true
    rescue => e
      nil
    end
  end
end
