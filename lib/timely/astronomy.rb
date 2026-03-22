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
  end
end
