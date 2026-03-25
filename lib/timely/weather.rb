require 'net/http'
require 'json'
require 'uri'

module Timely
  module Weather
    SYMBOLS = {
      0 => "\u2600",   # Clear sky
      1 => "\u{1F324}", # Mostly clear
      2 => "\u26C5",   # Partly cloudy
      3 => "\u2601",   # Cloudy
      5 => "\u{1F326}", # Rain showers
      6 => "\u{1F327}", # Rain
      8 => "\u{1F328}", # Snow
      9 => "\u{1F329}", # Thunder
    }.freeze

    # Fetch weather forecast from met.no
    # Returns hash of date_str => { temp_high:, temp_low:, symbol:, wind:, description: }
    def self.fetch(lat, lon, db = nil)
      # Check cache first (6 hour TTL)
      if db
        cached = db.execute(
          "SELECT data, fetched_at FROM weather_cache WHERE date = 'forecast' LIMIT 1"
        ).first
        if cached && (Time.now.to_i - cached['fetched_at'].to_i) < 21600
          return JSON.parse(cached['data']) rescue {}
        end
      end

      uri = URI("https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=#{lat}&lon=#{lon}")
      req = Net::HTTP::Get.new(uri)
      req['User-Agent'] = 'timely-calendar/0.1 g@isene.com'
      req['Accept-Encoding'] = 'identity'

      res = Net::HTTP.start(uri.hostname, uri.port,
                            use_ssl: true,
                            read_timeout: 10,
                            open_timeout: 5) do |http|
        http.request(req)
      end

      return {} unless res.is_a?(Net::HTTPSuccess)

      series = JSON.parse(res.body).dig('properties', 'timeseries') || []

      # Group by date, find high/low temps and midday conditions
      by_date = {}
      series.each do |ts|
        det = ts.dig('data', 'instant', 'details')
        next unless det
        time = ts['time']
        date = time[0..9]
        hour = time[11..12].to_i
        temp = det['air_temperature'].to_f

        by_date[date] ||= { temps: [], wind: 0, cloud: 0, midday_temp: nil }
        by_date[date][:temps] << temp
        # Capture midday (12:00) conditions for the symbol
        if hour == 12
          by_date[date][:midday_temp] = temp
          by_date[date][:wind] = det['wind_speed'].to_f.round(1)
          by_date[date][:cloud] = det['cloud_area_fraction'].to_i
        end
      end

      forecast = {}
      by_date.each do |date, data|
        cloud = data[:cloud]
        symbol = if cloud < 15
          SYMBOLS[0]
        elsif cloud < 40
          SYMBOLS[1]
        elsif cloud < 70
          SYMBOLS[2]
        else
          SYMBOLS[3]
        end

        temps = data[:temps]
        forecast[date] = {
          'temp_high' => temps.max.round(1),
          'temp_low' => temps.min.round(1),
          'temp_mid' => (data[:midday_temp] || temps[temps.size / 2]).round(1),
          'symbol' => symbol,
          'wind' => data[:wind],
          'cloud' => cloud
        }
      end

      # Cache result
      if db
        db.execute(
          "INSERT OR REPLACE INTO weather_cache (date, hour, data, fetched_at) VALUES (?, ?, ?, ?)",
          ['forecast', '00', JSON.generate(forecast), Time.now.to_i]
        )
      end

      forecast
    rescue SocketError, Timeout::Error, Net::OpenTimeout, Errno::ECONNREFUSED => e
      {}
    end

    # Get a short weather string for a date: "☀ 12°"
    def self.short_for_date(forecast, date)
      date_str = date.strftime('%Y-%m-%d')
      w = forecast[date_str]
      return nil unless w
      "#{w['symbol']} #{w['temp_mid']}°"
    end
  end
end
