require 'sqlite3'
require 'time'
require 'json'

module Timely
  class Database
    attr_reader :db

    SCHEMA_VERSION = 1

    def initialize(db_path = TIMELY_DB)
      @db_path = db_path
      @db = SQLite3::Database.new(@db_path)
      @db.results_as_hash = true
      @db.execute("PRAGMA journal_mode=WAL")
      @db.execute("PRAGMA busy_timeout=5000")
      setup_schema
    end

    def setup_schema
      # Schema version tracking
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS schema_version (
          version INTEGER PRIMARY KEY,
          applied_at INTEGER NOT NULL
        )
      SQL

      # Calendars table
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS calendars (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          source_type TEXT NOT NULL,
          source_config TEXT,
          color INTEGER DEFAULT 39,
          enabled INTEGER DEFAULT 1,
          sync_token TEXT,
          last_synced_at INTEGER,
          created_at INTEGER NOT NULL
        )
      SQL

      @db.execute "CREATE INDEX IF NOT EXISTS idx_calendars_enabled ON calendars(enabled)"

      # Events table
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          calendar_id INTEGER NOT NULL,
          external_id TEXT,
          title TEXT NOT NULL,
          description TEXT,
          location TEXT,
          start_time INTEGER NOT NULL,
          end_time INTEGER,
          all_day INTEGER DEFAULT 0,
          timezone TEXT,
          recurrence_rule TEXT,
          series_master_id INTEGER,
          status TEXT DEFAULT 'confirmed',
          organizer TEXT,
          attendees TEXT,
          my_status TEXT,
          alarms TEXT,
          metadata TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          FOREIGN KEY(calendar_id) REFERENCES calendars(id) ON DELETE CASCADE
        )
      SQL

      @db.execute "CREATE INDEX IF NOT EXISTS idx_events_calendar ON events(calendar_id)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_events_start ON events(start_time)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_events_end ON events(end_time)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_events_range ON events(start_time, end_time)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_events_external ON events(calendar_id, external_id)"

      # Settings table
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        )
      SQL

      # Weather cache
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS weather_cache (
          date TEXT NOT NULL,
          hour INTEGER,
          data TEXT,
          fetched_at INTEGER NOT NULL,
          PRIMARY KEY(date, hour)
        )
      SQL

      # Astronomy cache
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS astronomy_cache (
          date TEXT PRIMARY KEY,
          moon_phase REAL,
          moon_phase_name TEXT,
          events TEXT,
          fetched_at INTEGER NOT NULL
        )
      SQL

      migrate
      create_default_calendar
    end

    def migrate
      current_version = @db.get_first_value("SELECT MAX(version) FROM schema_version") || 0

      if current_version < SCHEMA_VERSION
        @db.transaction do
          @db.execute("INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     [SCHEMA_VERSION, Time.now.to_i])
        end
      end
    end

    def create_default_calendar
      count = @db.get_first_value("SELECT COUNT(*) FROM calendars")
      return if count && count > 0

      now = Time.now.to_i
      @db.execute(
        "INSERT INTO calendars (name, source_type, color, enabled, created_at) VALUES (?, ?, ?, ?, ?)",
        ['Personal', 'local', 39, 1, now]
      )
    end

    # Event operations

    def get_events_in_range(start_time, end_time)
      start_ts = start_time.is_a?(Time) ? start_time.to_i : start_time.to_i
      end_ts = end_time.is_a?(Time) ? end_time.to_i : end_time.to_i

      rows = @db.execute(
        "SELECT e.*, c.name as calendar_name, c.color as calendar_color
         FROM events e
         JOIN calendars c ON e.calendar_id = c.id
         WHERE c.enabled = 1
           AND e.start_time < ?
           AND (e.end_time > ? OR e.end_time IS NULL)
         ORDER BY e.start_time, e.title",
        [end_ts, start_ts]
      )
      rows.map { |row| normalize_event_row(row) }
    end

    def get_events_for_date(date)
      # date is a Date object; get all events that overlap this day
      start_ts = Time.new(date.year, date.month, date.day, 0, 0, 0).to_i
      end_ts = start_ts + 86400
      get_events_in_range(start_ts, end_ts)
    end

    def save_event(event_data)
      now = Time.now.to_i
      attendees_val = json_field(event_data[:attendees])
      alarms_val = json_field(event_data[:alarms])
      metadata_val = json_field(event_data[:metadata])

      if event_data[:id]
        @db.execute(
          "UPDATE events SET calendar_id=?, external_id=?, title=?, description=?,
           location=?, start_time=?, end_time=?, all_day=?, timezone=?,
           recurrence_rule=?, series_master_id=?, status=?, organizer=?, attendees=?, my_status=?,
           alarms=?, metadata=?, updated_at=? WHERE id=?",
          [
            event_data[:calendar_id], event_data[:external_id],
            event_data[:title], event_data[:description],
            event_data[:location], event_data[:start_time], event_data[:end_time],
            event_data[:all_day] ? 1 : 0, event_data[:timezone],
            event_data[:recurrence_rule], event_data[:series_master_id],
            event_data[:status],
            event_data[:organizer],
            attendees_val,
            event_data[:my_status],
            alarms_val,
            metadata_val,
            now, event_data[:id]
          ]
        )
        event_data[:id]
      else
        @db.execute(
          "INSERT INTO events (calendar_id, external_id, title, description,
           location, start_time, end_time, all_day, timezone,
           recurrence_rule, series_master_id, status, organizer, attendees, my_status,
           alarms, metadata, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [
            event_data[:calendar_id] || 1, event_data[:external_id],
            event_data[:title], event_data[:description],
            event_data[:location], event_data[:start_time], event_data[:end_time],
            event_data[:all_day] ? 1 : 0, event_data[:timezone],
            event_data[:recurrence_rule], event_data[:series_master_id],
            event_data[:status] || 'confirmed',
            event_data[:organizer],
            attendees_val,
            event_data[:my_status],
            alarms_val,
            metadata_val,
            now, now
          ]
        )
        @db.last_insert_row_id
      end
    end

    def delete_event(event_id)
      @db.execute("DELETE FROM events WHERE id = ?", [event_id])
    end

    # Calendar operations

    def get_calendars(enabled_only = true)
      query = enabled_only ? "SELECT * FROM calendars WHERE enabled = 1 ORDER BY id" : "SELECT * FROM calendars ORDER BY id"
      @db.execute(query)
    end

    def save_calendar(cal_data)
      now = Time.now.to_i
      config_val = json_field(cal_data[:source_config])
      if cal_data[:id]
        @db.execute(
          "UPDATE calendars SET name=?, source_type=?, source_config=?, color=?, enabled=?, sync_token=?, last_synced_at=? WHERE id=?",
          [cal_data[:name], cal_data[:source_type], config_val,
           cal_data[:color], cal_data[:enabled] ? 1 : 0,
           cal_data[:sync_token], cal_data[:last_synced_at], cal_data[:id]]
        )
      else
        @db.execute(
          "INSERT INTO calendars (name, source_type, source_config, color, enabled, created_at) VALUES (?, ?, ?, ?, ?, ?)",
          [cal_data[:name], cal_data[:source_type] || 'local',
           config_val, cal_data[:color] || 39,
           cal_data[:enabled] ? 1 : 0, now]
        )
        @db.last_insert_row_id
      end
    end

    # Settings operations

    def get_setting(key, default = nil)
      result = @db.get_first_value("SELECT value FROM settings WHERE key = ?", [key])
      return default unless result
      begin
        JSON.parse(result)
      rescue JSON::ParserError
        result
      end
    end

    def set_setting(key, value)
      now = Time.now.to_i
      value_str = value.is_a?(String) ? value : value.to_json
      @db.execute(
        "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
        [key, value_str, now]
      )
    end

    # Lookup helpers

    def event_exists?(calendar_id, external_id)
      return false unless external_id
      count = @db.get_first_value(
        "SELECT COUNT(*) FROM events WHERE calendar_id = ? AND external_id = ?",
        [calendar_id, external_id]
      )
      count.to_i > 0
    end

    # Check if a matching event exists on ANY calendar (cross-source dedup)
    # Matches on title + start_time (within 60s tolerance)
    def event_duplicate?(title, start_time)
      return false unless title && start_time
      count = @db.get_first_value(
        "SELECT COUNT(*) FROM events WHERE title = ? AND start_time BETWEEN ? AND ?",
        [title, start_time.to_i - 60, start_time.to_i + 60]
      )
      count.to_i > 0
    end

    def find_event_by_external_id(calendar_id, external_id)
      @db.execute(
        "SELECT * FROM events WHERE calendar_id = ? AND external_id = ? LIMIT 1",
        [calendar_id, external_id]
      ).first
    end

    def delete_event_by_external_id(calendar_id, external_id)
      @db.execute(
        "DELETE FROM events WHERE calendar_id = ? AND external_id = ?",
        [calendar_id, external_id]
      )
    end

    # Sync helpers

    def upsert_synced_event(calendar_id, evt)
      existing = find_event_by_external_id(calendar_id, evt[:external_id])
      if existing
        save_event(id: existing['id'], calendar_id: calendar_id, **evt)
        return :updated
      elsif event_duplicate?(evt[:title], evt[:start_time])
        return :skipped
      else
        save_event(calendar_id: calendar_id, **evt)
        return :new
      end
    end

    # Calendar update helpers

    def update_calendar_color(id, color)
      @db.execute("UPDATE calendars SET color = ? WHERE id = ?", [color, id])
    end

    def toggle_calendar_enabled(id)
      @db.execute("UPDATE calendars SET enabled = CASE WHEN enabled = 1 THEN 0 ELSE 1 END WHERE id = ?", [id])
    end

    def delete_calendar_with_events(id)
      @db.execute("DELETE FROM events WHERE calendar_id = ?", [id])
      @db.execute("DELETE FROM calendars WHERE id = ?", [id])
    end

    def update_calendar_sync(id, last_synced_at, source_config = nil)
      if source_config
        @db.execute("UPDATE calendars SET source_config = ?, last_synced_at = ? WHERE id = ?",
                    [source_config.is_a?(String) ? source_config : JSON.generate(source_config), last_synced_at, id])
      else
        @db.execute("UPDATE calendars SET last_synced_at = ? WHERE id = ?", [last_synced_at, id])
      end
    end

    # General operations

    def execute(query, params = [])
      @db.execute(query, params)
    end

    def transaction(&block)
      @db.transaction(&block)
    end

    def close
      @db.close if @db
    end

    private

    # Convert a value to JSON string for storage.
    # Handles values that are already JSON strings, arrays, or hashes.
    def json_field(value)
      return nil if value.nil?
      return value if value.is_a?(String)
      value.to_json
    end

    def normalize_event_row(row)
      r = row.dup
      %w[attendees alarms metadata].each do |field|
        r[field] = JSON.parse(r[field]) if r.key?(field) && r[field].is_a?(String)
      end
      r
    rescue JSON::ParserError
      row.dup
    end
  end
end
