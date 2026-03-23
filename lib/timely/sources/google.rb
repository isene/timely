require 'net/http'
require 'json'
require 'uri'
require 'time'

module Timely
  module Sources
    class Google
      API_BASE = 'https://www.googleapis.com'
      TOKEN_URL = 'https://oauth2.googleapis.com/token'

      def initialize(email, safe_dir: '/home/.safe/mail')
        @email = email
        @safe_dir = safe_dir
        @access_token = nil
        @token_expires_at = 0
      end

      # Get or refresh access token
      def get_access_token
        return @access_token if @access_token && Time.now.to_i < @token_expires_at

        json_file = Dir.glob(File.join(@safe_dir, '*.json')).first
        return nil unless json_file && File.exist?(json_file)

        creds = JSON.parse(File.read(json_file))
        client_id = creds.dig('web', 'client_id') || creds.dig('installed', 'client_id')
        client_secret = creds.dig('web', 'client_secret') || creds.dig('installed', 'client_secret')

        # Look for calendar-specific refresh token, fall back to general
        cal_token_file = File.join(@safe_dir, "#{@email}.calendar.txt")
        gen_token_file = File.join(@safe_dir, "#{@email}.txt")
        token_file = File.exist?(cal_token_file) ? cal_token_file : gen_token_file
        return nil unless File.exist?(token_file)

        refresh_token = File.read(token_file).strip
        return nil if refresh_token.empty?

        # Token refresh via API
        uri = URI(TOKEN_URL)
        res = Net::HTTP.post_form(uri, {
          'client_id' => client_id,
          'client_secret' => client_secret,
          'refresh_token' => refresh_token,
          'grant_type' => 'refresh_token'
        })

        if res.is_a?(Net::HTTPSuccess)
          data = JSON.parse(res.body)
          @access_token = data['access_token']
          @token_expires_at = Time.now.to_i + (data['expires_in'] || 3600).to_i - 60
          @access_token
        else
          nil
        end
      rescue => e
        nil
      end

      # List all calendars
      def list_calendars
        data = api_get('/calendar/v3/users/me/calendarList')
        return [] unless data && data['items']
        data['items'].map do |cal|
          {
            id: cal['id'],
            summary: cal['summary'],
            primary: cal['primary'] || false,
            color: cal['backgroundColor'],
            access_role: cal['accessRole']
          }
        end
      end

      # Fetch events in a date range
      def fetch_events(calendar_id, time_min, time_max)
        events = []
        page_token = nil

        loop do
          params = {
            'timeMin' => Time.at(time_min).utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'timeMax' => Time.at(time_max).utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'singleEvents' => 'true',
            'maxResults' => '250',
            'orderBy' => 'startTime'
          }
          params['pageToken'] = page_token if page_token

          query = params.map { |k, v| "#{k}=#{URI.encode_www_form_component(v)}" }.join('&')
          cal_encoded = URI.encode_www_form_component(calendar_id)
          data = api_get("/calendar/v3/calendars/#{cal_encoded}/events?#{query}")
          break unless data && data['items']

          data['items'].each do |item|
            events << normalize_event(item)
          end

          page_token = data['nextPageToken']
          break unless page_token
        end

        events
      end

      # Create event on Google Calendar
      def create_event(calendar_id, event_data)
        body = to_google_format(event_data)
        cal_encoded = URI.encode_www_form_component(calendar_id)
        data = api_post("/calendar/v3/calendars/#{cal_encoded}/events", body)
        data ? data['id'] : nil
      end

      # Update event
      def update_event(calendar_id, event_id, event_data)
        body = to_google_format(event_data)
        cal_encoded = URI.encode_www_form_component(calendar_id)
        evt_encoded = URI.encode_www_form_component(event_id)
        api_put("/calendar/v3/calendars/#{cal_encoded}/events/#{evt_encoded}", body)
      end

      # Delete event
      def delete_event(calendar_id, event_id)
        cal_encoded = URI.encode_www_form_component(calendar_id)
        evt_encoded = URI.encode_www_form_component(event_id)
        api_delete("/calendar/v3/calendars/#{cal_encoded}/events/#{evt_encoded}")
      end

      private

      def normalize_event(item)
        start_data = item['start'] || {}
        end_data = item['end'] || {}

        all_day = start_data.key?('date') && !start_data.key?('dateTime')

        start_time = if start_data['dateTime']
          Time.parse(start_data['dateTime']).to_i
        elsif start_data['date']
          Date.parse(start_data['date']).to_time.to_i
        else
          0
        end

        end_time = if end_data['dateTime']
          Time.parse(end_data['dateTime']).to_i
        elsif end_data['date']
          Date.parse(end_data['date']).to_time.to_i
        else
          start_time + 3600
        end

        attendees = (item['attendees'] || []).map do |a|
          { 'email' => a['email'], 'name' => a['displayName'], 'status' => a['responseStatus'] }
        end

        my_status = nil
        if item['attendees']
          me = item['attendees'].find { |a| a['self'] }
          my_status = me['responseStatus'] if me
        end

        {
          external_id: item['id'],
          title: item['summary'] || '(No title)',
          description: item['description'],
          location: item['location'],
          start_time: start_time,
          end_time: end_time,
          all_day: all_day,
          status: item['status'] || 'confirmed',
          organizer: item.dig('organizer', 'email'),
          attendees: attendees.empty? ? nil : attendees,
          my_status: my_status,
          metadata: { 'google_calendar_id' => item.dig('organizer', 'email'), 'html_link' => item['htmlLink'] }
        }
      end

      def to_google_format(event_data)
        body = { 'summary' => event_data[:title] }
        body['description'] = event_data[:description] if event_data[:description]
        body['location'] = event_data[:location] if event_data[:location]

        if event_data[:all_day]
          st = Time.at(event_data[:start_time])
          et = Time.at(event_data[:end_time])
          body['start'] = { 'date' => st.strftime('%Y-%m-%d') }
          body['end'] = { 'date' => et.strftime('%Y-%m-%d') }
        else
          body['start'] = { 'dateTime' => Time.at(event_data[:start_time]).iso8601 }
          body['end'] = { 'dateTime' => Time.at(event_data[:end_time]).iso8601 }
        end

        if event_data[:attendees]
          body['attendees'] = event_data[:attendees].map { |a| { 'email' => a['email'] || a[:email] } }
        end

        body
      end

      def api_get(path)
        token = get_access_token
        return nil unless token
        uri = URI("#{API_BASE}#{path}")
        req = Net::HTTP::Get.new(uri)
        req['Authorization'] = "Bearer #{token}"
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 15) { |http| http.request(req) }
        res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
      rescue => e
        nil
      end

      def api_post(path, body)
        token = get_access_token
        return nil unless token
        uri = URI("#{API_BASE}#{path}")
        req = Net::HTTP::Post.new(uri)
        req['Authorization'] = "Bearer #{token}"
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 15) { |http| http.request(req) }
        res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
      rescue => e
        nil
      end

      def api_put(path, body)
        token = get_access_token
        return nil unless token
        uri = URI("#{API_BASE}#{path}")
        req = Net::HTTP::Put.new(uri)
        req['Authorization'] = "Bearer #{token}"
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 15) { |http| http.request(req) }
        res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
      rescue => e
        nil
      end

      def api_delete(path)
        token = get_access_token
        return nil unless token
        uri = URI("#{API_BASE}#{path}")
        req = Net::HTTP::Delete.new(uri)
        req['Authorization'] = "Bearer #{token}"
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 15) { |http| http.request(req) }
        res.is_a?(Net::HTTPSuccess) || res.code == '204'
      rescue => e
        false
      end
    end
  end
end
