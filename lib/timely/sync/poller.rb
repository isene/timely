module Timely
  module Sync
    class Poller
      def initialize(db, config)
        @db = db
        @config = config
        @running = false
        @needs_refresh = false
        @thread = nil
      end

      def start
        return if @running
        @running = true
        interval = @config.get('google.sync_interval', 300)

        @thread = Thread.new do
          while @running
            begin
              sync_cycle
            rescue => e
              File.open('/tmp/timely-sync.log', 'a') { |f| f.puts "#{Time.now} Sync error: #{e.message}" }
            end
            # Sleep in short intervals so we can exit quickly
            (interval / 2).times { break unless @running; sleep 2 }
          end
        end
      end

      def stop
        @running = false
        @thread&.kill
      end

      def needs_refresh?
        @needs_refresh
      end

      def clear_refresh_flag
        @needs_refresh = false
      end

      private

      def sync_cycle
        calendars = @db.get_calendars.select { |c| c['source_type'] == 'google' }
        return if calendars.empty?

        calendars.each do |cal|
          sync_calendar(cal)
        end
      end

      def sync_calendar(cal)
        config = cal['source_config']
        config = JSON.parse(config) if config.is_a?(String)
        return unless config.is_a?(Hash)

        email = config['email']
        safe_dir = config['safe_dir'] || '/home/.safe/mail'
        google = Sources::Google.new(email, safe_dir: safe_dir)

        return unless google.get_access_token

        gcal_id = config['google_calendar_id'] || email

        # Fetch events for a 6-month window
        now = Time.now
        time_min = (now - 90 * 86400).to_i
        time_max = (now + 90 * 86400).to_i

        events = google.fetch_events(gcal_id, time_min, time_max)
        return unless events

        changed = false
        events.each do |evt|
          existing = @db.find_event_by_external_id(cal['id'], evt[:external_id])
          if existing
            @db.save_event(
              id: existing['id'],
              calendar_id: cal['id'],
              external_id: evt[:external_id],
              title: evt[:title],
              description: evt[:description],
              location: evt[:location],
              start_time: evt[:start_time],
              end_time: evt[:end_time],
              all_day: evt[:all_day],
              status: evt[:status],
              organizer: evt[:organizer],
              attendees: evt[:attendees],
              my_status: evt[:my_status],
              metadata: evt[:metadata]
            )
          elsif @db.event_duplicate?(evt[:title], evt[:start_time])
            # Already imported via ICS; skip
          else
            @db.save_event(
              calendar_id: cal['id'],
              external_id: evt[:external_id],
              title: evt[:title],
              description: evt[:description],
              location: evt[:location],
              start_time: evt[:start_time],
              end_time: evt[:end_time],
              all_day: evt[:all_day],
              status: evt[:status],
              organizer: evt[:organizer],
              attendees: evt[:attendees],
              my_status: evt[:my_status],
              metadata: evt[:metadata]
            )
            changed = true
          end
        end

        # Update last_synced
        @db.db.execute("UPDATE calendars SET last_synced_at = ? WHERE id = ?", [Time.now.to_i, cal['id']])
        @needs_refresh = true if changed
      end
    end
  end
end
