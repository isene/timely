module Timely
  class Event
    ATTRS = %i[
      id calendar_id external_id title description location
      start_time end_time all_day timezone recurrence_rule
      status organizer attendees my_status alarms metadata
      calendar_name calendar_color
    ].freeze

    attr_accessor *ATTRS

    def initialize(attrs = {})
      attrs.each do |key, value|
        sym = key.to_sym
        send(:"#{sym}=", value) if respond_to?(:"#{sym}=")
      end
    end

    def to_h
      ATTRS.each_with_object({}) do |attr, hash|
        hash[attr] = send(attr)
      end
    end

    def self.from_h(hash)
      new(hash)
    end

    def self.from_row(row)
      attrs = {}
      row.each do |key, value|
        attrs[key.to_sym] = value
      end
      new(attrs)
    end

    def duration_minutes
      return 0 unless start_time && end_time
      ((end_time.to_i - start_time.to_i) / 60.0).round
    end

    def start_date
      return nil unless start_time
      Time.at(start_time.to_i).to_date
    end

    def end_date
      return nil unless end_time
      Time.at(end_time.to_i).to_date
    end

    def time_range_str
      return "All day" if all_day && all_day != 0
      return "" unless start_time

      st = Time.at(start_time.to_i)
      result = st.strftime("%H:%M")

      if end_time
        et = Time.at(end_time.to_i)
        result += " - #{et.strftime('%H:%M')}"
      end

      result
    end

    def date_str
      return "" unless start_time
      Time.at(start_time.to_i).strftime("%Y-%m-%d")
    end

    def title_str
      title || "(No title)"
    end
  end
end
