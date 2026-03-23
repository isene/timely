require 'time'
require 'date'

module Timely
  module Sources
    module IcsFile
      # Parse ICS content, return array of event hashes
      def self.parse(ics_content)
        events = []
        # Split into VEVENT blocks
        ics_content.scan(/BEGIN:VEVENT(.*?)END:VEVENT/m).each do |match|
          vevent = match[0]
          # Unfold continuation lines (RFC 5545)
          vevent = vevent.gsub(/\r?\n[ \t]/, '')
          evt = parse_vevent(vevent)
          events << evt if evt
        end
        events
      end

      # Parse a single VEVENT block
      def self.parse_vevent(vevent)
        event = {}

        # SUMMARY
        event[:title] = $1.strip if vevent =~ /^SUMMARY[^:]*:(.*)$/i

        # DTSTART
        start_time, all_day = parse_dt(vevent, 'DTSTART')
        return nil unless start_time
        event[:start_time] = start_time.to_i
        event[:all_day] = all_day

        # DTEND
        end_time, _ = parse_dt(vevent, 'DTEND')
        event[:end_time] = end_time ? end_time.to_i : (all_day ? start_time.to_i + 86400 : start_time.to_i + 3600)

        # LOCATION
        event[:location] = $1.strip if vevent =~ /^LOCATION[^:]*:(.*)$/i

        # DESCRIPTION
        if vevent =~ /^DESCRIPTION[^:]*:(.*?)(?=^[A-Z])/mi
          desc = $1.gsub(/\\n/, "\n").gsub(/\\,/, ',').gsub(/\\;/, ';').strip
          event[:description] = desc unless desc.empty?
        end

        # ORGANIZER
        if vevent =~ /^ORGANIZER.*CN=([^;:]+)/i
          event[:organizer] = $1.strip
        elsif vevent =~ /^ORGANIZER.*MAILTO:(.+)$/i
          event[:organizer] = $1.strip
        end

        # ATTENDEES
        attendees = vevent.scan(/^ATTENDEE.*CN=([^;:]+)/i).flatten
        event[:attendees] = attendees.map { |a| { 'email' => a.strip } } if attendees.any?

        # STATUS
        event[:status] = $1.strip.downcase if vevent =~ /^STATUS:(.*)$/i

        # UID (used as external_id)
        event[:uid] = $1.strip if vevent =~ /^UID:(.*)$/i

        # RRULE
        event[:rrule] = $1.strip if vevent =~ /^RRULE:(.*)$/i

        # VALARM
        if vevent =~ /TRIGGER[^:]*:(-?)P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?/i
          days = ($2 || 0).to_i
          hours = ($3 || 0).to_i
          mins = ($4 || 0).to_i
          total_mins = days * 1440 + hours * 60 + mins
          event[:alarms] = [total_mins]
        end

        event
      end

      # Parse DTSTART or DTEND from VEVENT text
      # Returns [Time, all_day_boolean]
      def self.parse_dt(vevent, field)
        if vevent =~ /^#{field};TZID=[^:]*:(\d{8})T(\d{4,6})/i
          d, t = $1, $2
          time = Time.new(d[0,4].to_i, d[4,2].to_i, d[6,2].to_i, t[0,2].to_i, t[2,2].to_i)
          [time, false]
        elsif vevent =~ /^#{field};VALUE=DATE:(\d{8})/i
          d = $1
          [Time.new(d[0,4].to_i, d[4,2].to_i, d[6,2].to_i), true]
        elsif vevent =~ /^#{field}:(\d{8})T(\d{4,6})(Z)?/i
          d, t, utc = $1, $2, $3
          if utc
            Time.utc(d[0,4].to_i, d[4,2].to_i, d[6,2].to_i, t[0,2].to_i, t[2,2].to_i).localtime
          else
            Time.new(d[0,4].to_i, d[4,2].to_i, d[6,2].to_i, t[0,2].to_i, t[2,2].to_i)
          end.then { |time| [time, false] }
        elsif vevent =~ /^#{field}:(\d{8})/i
          d = $1
          [Time.new(d[0,4].to_i, d[4,2].to_i, d[6,2].to_i), true]
        else
          [nil, false]
        end
      end

      # Expand RRULE into occurrence [start_ts, end_ts] pairs
      def self.expand_rrule(rrule, dtstart_ts, dtend_ts, max_occurrences: 365, horizon_days: 365)
        parts = {}
        rrule.split(';').each do |p|
          k, v = p.split('=', 2)
          parts[k] = v
        end

        freq = parts['FREQ']
        interval = (parts['INTERVAL'] || '1').to_i
        count = parts['COUNT']&.to_i
        until_str = parts['UNTIL']

        until_time = nil
        if until_str
          if until_str.length >= 8
            d = until_str
            until_time = Time.new(d[0,4].to_i, d[4,2].to_i, d[6,2].to_i, 23, 59, 59)
          end
        end

        horizon = Time.at(dtstart_ts) + horizon_days * 86400
        duration = dtend_ts - dtstart_ts

        occurrences = []
        current = Time.at(dtstart_ts)
        n = 0

        loop do
          n += 1
          current = case freq
                    when 'DAILY'  then current + interval * 86400
                    when 'WEEKLY' then current + interval * 7 * 86400
                    when 'MONTHLY'
                      y, m = current.year, current.month
                      m += interval
                      while m > 12; m -= 12; y += 1; end
                      d = [current.day, Date.new(y, m, -1).day].min
                      Time.new(y, m, d, current.hour, current.min)
                    when 'YEARLY'
                      y = current.year + interval
                      m, d = current.month, current.day
                      d = [d, Date.new(y, m, -1).day].min rescue d
                      Time.new(y, m, d, current.hour, current.min)
                    else
                      break
                    end

          break if count && n >= count
          break if until_time && current > until_time
          break if current > horizon
          break if occurrences.size >= max_occurrences

          st = current.to_i
          occurrences << [st, st + duration]
        end

        occurrences
      end

      # Import events from ICS file into database
      def self.import_file(file_path, db, calendar_id: 1)
        content = File.read(file_path)
        content = content.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?') rescue content.force_encoding('UTF-8').scrub('?')

        events = parse(content)
        imported = 0
        skipped = 0

        events.each do |evt|
          # Skip duplicates: by UID on same calendar, or by title+time across all calendars
          if evt[:uid] && db.event_exists?(calendar_id, evt[:uid])
            skipped += 1
            next
          end
          if db.event_duplicate?(evt[:title], evt[:start_time])
            skipped += 1
            next
          end

          master_id = db.save_event(
            calendar_id: calendar_id,
            external_id: evt[:uid],
            title: evt[:title] || '(No title)',
            description: evt[:description],
            location: evt[:location],
            start_time: evt[:start_time],
            end_time: evt[:end_time],
            all_day: evt[:all_day],
            status: evt[:status] || 'confirmed',
            organizer: evt[:organizer],
            attendees: evt[:attendees],
            alarms: evt[:alarms],
            recurrence_rule: evt[:rrule]
          )
          imported += 1

          # Expand recurring events
          if evt[:rrule] && master_id
            occurrences = expand_rrule(evt[:rrule], evt[:start_time], evt[:end_time])
            occurrences.each do |st, et|
              db.save_event(
                calendar_id: calendar_id,
                external_id: "#{evt[:uid]}_#{st}",
                title: evt[:title] || '(No title)',
                description: evt[:description],
                location: evt[:location],
                start_time: st,
                end_time: et,
                all_day: evt[:all_day],
                status: evt[:status] || 'confirmed',
                organizer: evt[:organizer],
                attendees: evt[:attendees],
                series_master_id: master_id
              )
              imported += 1
            end
          end
        end

        { imported: imported, skipped: skipped }
      rescue => e
        { imported: imported || 0, skipped: skipped || 0, error: e.message }
      end

      # Check incoming directory for ICS files, import them
      def self.watch_incoming(db, calendar_id: 1, dir: nil)
        dir ||= File.join(TIMELY_HOME, 'incoming')
        FileUtils.mkdir_p(dir)
        processed_dir = File.join(dir, 'processed')
        FileUtils.mkdir_p(processed_dir)

        total_imported = 0
        Dir.glob(File.join(dir, '*.ics')).each do |file|
          result = import_file(file, db, calendar_id: calendar_id)
          total_imported += result[:imported]
          # Move to processed
          FileUtils.mv(file, File.join(processed_dir, File.basename(file))) rescue nil
        end
        total_imported
      end
    end
  end
end
