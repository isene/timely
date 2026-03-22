module Timely
  module Astronomy
    PHASE_NAMES = [
      'New Moon', 'Waxing Crescent', 'First Quarter', 'Waxing Gibbous',
      'Full Moon', 'Waning Gibbous', 'Last Quarter', 'Waning Crescent'
    ].freeze

    PHASE_SYMBOLS = [
      "\u{1F311}", "\u{1F312}", "\u{1F313}", "\u{1F314}",
      "\u{1F315}", "\u{1F316}", "\u{1F317}", "\u{1F318}"
    ].freeze

    # Calculate moon phase for a given Date.
    # Returns a hash with :illumination (0.0-1.0), :phase_name, :symbol, :phase_index
    def self.moon_phase(date)
      # Julian date calculation
      y = date.year
      m = date.month
      d = date.day

      jd = 367 * y - (7 * (y + ((m + 9) / 12))) / 4 + (275 * m) / 9 + d + 1721013.5

      # Days since known new moon (Jan 6, 2000 18:14 UTC)
      # Reference epoch: JD 2451550.1 (known new moon)
      days_since = jd - 2451550.1
      synodic_month = 29.530588853

      # Normalize to 0.0 - 1.0 within synodic month
      phase = (days_since / synodic_month) % 1.0
      phase = phase + 1.0 if phase < 0

      # Map phase position to illumination (0 = new, 0.5 = full)
      # Illumination follows a cosine curve
      illumination = (1.0 - Math.cos(phase * 2 * Math::PI)) / 2.0

      # Determine phase index (0-7)
      phase_index = (phase * 8).floor % 8

      {
        illumination: illumination.round(4),
        phase: phase.round(4),
        phase_name: PHASE_NAMES[phase_index],
        symbol: PHASE_SYMBOLS[phase_index],
        phase_index: phase_index
      }
    end

    # Return a short symbol for display in calendar cells
    def self.moon_symbol(date)
      moon_phase(date)[:symbol]
    end

    # Check if this is a notable phase (new, first quarter, full, last quarter).
    # Only returns true on the day closest to the exact phase transition.
    def self.notable_phase?(date)
      today_phase = moon_phase(date)
      index = today_phase[:phase_index]
      return false unless [0, 2, 4, 6].include?(index)

      # Check if yesterday had a different phase index
      yesterday = moon_phase(date - 1)
      yesterday[:phase_index] != index
    end

    # Find all notable moon phase dates within a month.
    # Returns array of { date:, phase_name:, symbol: }
    def self.notable_phases_in_month(year, month)
      last_day = Date.new(year, month, -1).day
      result = []
      (1..last_day).each do |d|
        date = Date.new(year, month, d)
        if notable_phase?(date)
          p = moon_phase(date)
          result << { date: date, day: d, phase_name: p[:phase_name], symbol: p[:symbol] }
        end
      end
      result
    end

    # Sunrise/sunset for a given date and location.
    # Returns { rise: "HH:MM", set: "HH:MM" }
    def self.sun_times(date, lat = 59.9139, lon = 10.7522, tz = 1)
      load_ephemeris
      return nil unless defined?(Ephemeris)
      eph = Ephemeris.new(date.strftime('%Y-%m-%d'), lat, lon, tz)
      rise, _, sett = eph.rts(eph.sun[0], eph.sun[1])
      { rise: rise.is_a?(String) ? rise[0..4] : rise.to_s,
        set: sett.is_a?(String) ? sett[0..4] : sett.to_s }
    rescue => e
      nil
    end

    def self.load_ephemeris
      return if defined?(Ephemeris)
      begin
        require 'ephemeris'
      rescue LoadError
        path = File.expand_path('~/Main/G/GIT-isene/ephemeris/lib/ephemeris.rb')
        require path if File.exist?(path)
      end
    end

    PLANET_SYMBOLS = {
      'mercury' => "\u263F", 'venus' => "\u2640", 'mars' => "\u2642",
      'jupiter' => "\u2643", 'saturn' => "\u2644"
    }.freeze

    # RGB colors matching astropanel
    BODY_COLORS = {
      'sun'     => 'FFD700',
      'moon'    => '888888',
      'mercury' => '8F6E54',
      'venus'   => 'E6B07C',
      'mars'    => 'BC2732',
      'jupiter' => 'C08040',
      'saturn'  => 'E8D9A0'
    }.freeze

    # Returns array of planet names visible at night for the given date/location.
    # A planet is "visible" if altitude > 5 degrees at any hour between 20:00-04:00.
    def self.visible_planets(date, lat = 59.9139, lon = 10.7522, tz = 1)
      load_ephemeris
      return [] unless defined?(Ephemeris)

      date_str = date.strftime('%Y-%m-%d')
      eph = Ephemeris.new(date_str, lat, lon, tz)
      visible = []

      %w[mercury venus mars jupiter saturn].each do |planet|
        # Check altitude at evening/night hours
        [20.0, 21.0, 22.0, 23.0, 0.0, 1.0, 2.0, 3.0, 4.0].any? do |h|
          alt, _ = eph.body_alt_az(planet, h)
          if alt > 5
            body = eph.send(planet)
            visible << {
              name: planet.capitalize,
              symbol: PLANET_SYMBOLS[planet],
              rise: body[5].is_a?(String) ? body[5][0..4] : body[5].to_s,
              set: body[7].is_a?(String) ? body[7][0..4] : body[7].to_s
            }
            true
          end
        end
      end
      visible
    rescue => e
      []
    end

    # Notable astronomical events for a date (simple rule-based).
    # Returns array of event description strings.
    def self.astro_events(date, lat = 59.9139, lon = 10.7522, tz = 1)
      events = []

      # Check for notable moon phase
      phase = moon_phase(date)
      if notable_phase?(date)
        events << "#{phase[:symbol]} #{phase[:phase_name]}"
      end

      # Check for solstices and equinoxes
      m, d = date.month, date.day
      events << "\u2600 Summer Solstice" if m == 6 && d == 21
      events << "\u2744 Winter Solstice" if m == 12 && d == 21
      events << "\u2600 Vernal Equinox" if m == 3 && d == 20
      events << "\u2600 Autumnal Equinox" if m == 9 && d == 22

      # Major meteor showers (peak dates)
      events << "\u2604 Quadrantids peak" if m == 1 && d == 3
      events << "\u2604 Lyrids peak" if m == 4 && d == 22
      events << "\u2604 Eta Aquariids peak" if m == 5 && d == 6
      events << "\u2604 Perseids peak" if m == 8 && d == 12
      events << "\u2604 Orionids peak" if m == 10 && d == 21
      events << "\u2604 Leonids peak" if m == 11 && d == 17
      events << "\u2604 Geminids peak" if m == 12 && d == 14

      events
    end
  end
end
