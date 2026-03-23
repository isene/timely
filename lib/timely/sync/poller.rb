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
        # Sync Google calendars
        google_calendars = @db.get_calendars.select { |c| c['source_type'] == 'google' }
        google_calendars.each { |cal| sync_calendar(cal) }

        # Sync Outlook calendars
        outlook_calendars = @db.get_calendars.select { |c| c['source_type'] == 'outlook' }
        outlook_calendars.each { |cal| sync_outlook_calendar(cal) }

        # Check for upcoming event notifications
        Notifications.check_and_notify(@db)
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
          changed = true if @db.upsert_synced_event(cal['id'], evt) == :new
        end

        @db.update_calendar_sync(cal['id'], Time.now.to_i)
        @needs_refresh = true if changed
      end

      def sync_outlook_calendar(cal)
        config = cal['source_config']
        config = JSON.parse(config) if config.is_a?(String)
        return unless config.is_a?(Hash)

        outlook = Sources::Outlook.new(config)
        return unless outlook.refresh_access_token

        # Fetch events for a 6-month window
        now = Time.now
        time_min = (now - 90 * 86400).to_i
        time_max = (now + 90 * 86400).to_i

        events = outlook.fetch_events(time_min, time_max)
        return unless events

        changed = false
        events.each do |evt|
          changed = true if @db.upsert_synced_event(cal['id'], evt) == :new
        end

        # Persist refreshed tokens back to source_config
        new_config = config.merge(
          'access_token' => outlook.instance_variable_get(:@access_token),
          'refresh_token' => outlook.instance_variable_get(:@refresh_token)
        )
        @db.update_calendar_sync(cal['id'], Time.now.to_i, new_config)
        @needs_refresh = true if changed
      end
    end
  end
end
