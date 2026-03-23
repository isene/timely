require 'net/http'
require 'json'
require 'uri'
require 'time'

module Timely
  module Sources
    class Outlook
      GRAPH_BASE = 'https://graph.microsoft.com/v1.0'
      AUTH_URL = 'https://login.microsoftonline.com/common/oauth2/v2.0'
      SCOPES = 'Calendars.ReadWrite offline_access'

      attr_reader :last_error

      def initialize(config = {})
        @client_id = config['client_id']
        @tenant_id = config['tenant_id'] || 'common'
        @access_token = config['access_token']
        @refresh_token = config['refresh_token']
        @token_expires_at = 0
        @last_error = nil
      end

      # Device code flow - Step 1: get device code
      # Returns { user_code:, device_code:, verification_uri:, message: }
      def start_device_auth
        uri = URI("#{AUTH_URL.sub('common', @tenant_id)}/devicecode")
        res = Net::HTTP.post_form(uri, {
          'client_id' => @client_id,
          'scope' => SCOPES
        })
        if res.is_a?(Net::HTTPSuccess)
          JSON.parse(res.body)
        else
          @last_error = "Device auth failed: #{res.code}"
          nil
        end
      rescue => e
        @last_error = e.message
        nil
      end

      # Device code flow - Step 2: poll for token
      def poll_for_token(device_code)
        uri = URI("#{AUTH_URL.sub('common', @tenant_id)}/token")
        loop do
          res = Net::HTTP.post_form(uri, {
            'client_id' => @client_id,
            'grant_type' => 'urn:ietf:params:oauth:grant-type:device_code',
            'device_code' => device_code
          })
          data = JSON.parse(res.body)
          if data['access_token']
            @access_token = data['access_token']
            @refresh_token = data['refresh_token']
            @token_expires_at = Time.now.to_i + (data['expires_in'] || 3600).to_i - 60
            return { access_token: @access_token, refresh_token: @refresh_token }
          elsif data['error'] == 'authorization_pending'
            sleep 5
          elsif data['error'] == 'slow_down'
            sleep 10
          else
            @last_error = data['error_description'] || data['error']
            return nil
          end
        end
      rescue => e
        @last_error = e.message
        nil
      end

      # Refresh access token
      def refresh_access_token
        return @access_token if @access_token && Time.now.to_i < @token_expires_at
        return nil unless @refresh_token && @client_id

        uri = URI("#{AUTH_URL.sub('common', @tenant_id)}/token")
        res = Net::HTTP.post_form(uri, {
          'client_id' => @client_id,
          'grant_type' => 'refresh_token',
          'refresh_token' => @refresh_token,
          'scope' => SCOPES
        })

        if res.is_a?(Net::HTTPSuccess)
          data = JSON.parse(res.body)
          @access_token = data['access_token']
          @refresh_token = data['refresh_token'] if data['refresh_token']
          @token_expires_at = Time.now.to_i + (data['expires_in'] || 3600).to_i - 60
          @access_token
        else
          @last_error = "Token refresh failed: #{res.code}"
          nil
        end
      rescue => e
        @last_error = e.message
        nil
      end

      # List calendars
      def list_calendars
        data = api_get('/me/calendars')
        return [] unless data && data['value']
        data['value'].map do |cal|
          { id: cal['id'], name: cal['name'], color: cal['color'], can_edit: cal['canEdit'] }
        end
      end

      # Fetch events for a date range
      def fetch_events(time_min, time_max)
        start_str = Time.at(time_min).utc.strftime('%Y-%m-%dT%H:%M:%SZ')
        end_str = Time.at(time_max).utc.strftime('%Y-%m-%dT%H:%M:%SZ')

        events = []
        url = "/me/calendarView?startDateTime=#{start_str}&endDateTime=#{end_str}&$top=250&$orderby=start/dateTime"

        while url
          data = api_get(url)
          break unless data && data['value']
          data['value'].each { |item| events << normalize_event(item) }
          url = data['@odata.nextLink']&.sub(GRAPH_BASE, '')
        end
        events
      end

      # Create event
      def create_event(event_data)
        body = to_outlook_format(event_data)
        data = api_post('/me/events', body)
        data ? data['id'] : nil
      end

      # Update event
      def update_event(event_id, event_data)
        body = to_outlook_format(event_data)
        api_patch("/me/events/#{event_id}", body)
      end

      # Delete event
      def delete_event(event_id)
        api_delete("/me/events/#{event_id}")
      end

      # Accept/decline/tentative
      def respond_to_event(event_id, response)
        endpoint = case response.to_s
                   when 'accepted', 'accept' then 'accept'
                   when 'declined', 'decline' then 'decline'
                   when 'tentative', 'tentativelyAccept' then 'tentativelyAccept'
                   else return false
                   end
        api_post("/me/events/#{event_id}/#{endpoint}", { 'sendResponse' => true })
      end

      private

      def normalize_event(item)
        start_data = item['start'] || {}
        end_data = item['end'] || {}

        all_day = item['isAllDay'] || false

        start_time = if start_data['dateTime']
          tz_suffix = start_data['timeZone'] == 'UTC' ? 'Z' : ''
          Time.parse(start_data['dateTime'] + tz_suffix).to_i
        else
          0
        end

        end_time = if end_data['dateTime']
          tz_suffix = end_data['timeZone'] == 'UTC' ? 'Z' : ''
          Time.parse(end_data['dateTime'] + tz_suffix).to_i
        else
          start_time + 3600
        end

        attendees = (item['attendees'] || []).map do |a|
          { 'email' => a.dig('emailAddress', 'address'),
            'name' => a.dig('emailAddress', 'name'),
            'status' => a.dig('status', 'response') }
        end

        {
          external_id: item['id'],
          title: item['subject'] || '(No title)',
          description: item.dig('body', 'content'),
          location: item.dig('location', 'displayName'),
          start_time: start_time,
          end_time: end_time,
          all_day: all_day,
          status: item['showAs'] || 'busy',
          organizer: item.dig('organizer', 'emailAddress', 'address'),
          attendees: attendees.empty? ? nil : attendees,
          my_status: item.dig('responseStatus', 'response'),
          metadata: { 'outlook' => true, 'web_link' => item['webLink'] }
        }
      end

      def to_outlook_format(event_data)
        body = { 'subject' => event_data[:title] }
        body['body'] = { 'contentType' => 'text', 'content' => event_data[:description] } if event_data[:description]
        body['location'] = { 'displayName' => event_data[:location] } if event_data[:location]
        body['isAllDay'] = event_data[:all_day] || false

        if event_data[:all_day]
          st = Time.at(event_data[:start_time])
          et = Time.at(event_data[:end_time])
          body['start'] = { 'dateTime' => st.strftime('%Y-%m-%dT00:00:00'), 'timeZone' => 'UTC' }
          body['end'] = { 'dateTime' => et.strftime('%Y-%m-%dT00:00:00'), 'timeZone' => 'UTC' }
        else
          body['start'] = { 'dateTime' => Time.at(event_data[:start_time]).utc.strftime('%Y-%m-%dT%H:%M:%S'), 'timeZone' => 'UTC' }
          body['end'] = { 'dateTime' => Time.at(event_data[:end_time]).utc.strftime('%Y-%m-%dT%H:%M:%S'), 'timeZone' => 'UTC' }
        end

        if event_data[:attendees]
          body['attendees'] = event_data[:attendees].map do |a|
            { 'emailAddress' => { 'address' => a['email'] || a[:email] }, 'type' => 'required' }
          end
        end
        body
      end

      def api_get(path)
        token = refresh_access_token
        return nil unless token
        full_url = path.start_with?('http') ? path : "#{GRAPH_BASE}#{path}"
        uri = URI(full_url)
        req = Net::HTTP::Get.new(uri)
        req['Authorization'] = "Bearer #{token}"
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30, open_timeout: 10) { |http| http.request(req) }
        if res.is_a?(Net::HTTPSuccess)
          JSON.parse(res.body)
        else
          @last_error = "API #{res.code}: #{res.body[0..200] rescue ''}"
          nil
        end
      rescue Timeout::Error, Net::OpenTimeout, SocketError, Errno::ECONNREFUSED => e
        @last_error = "Network error: #{e.message}"
        nil
      rescue => e
        @last_error = e.message
        nil
      end

      def api_post(path, body)
        token = refresh_access_token
        return nil unless token
        uri = URI("#{GRAPH_BASE}#{path}")
        req = Net::HTTP::Post.new(uri)
        req['Authorization'] = "Bearer #{token}"
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30, open_timeout: 10) { |http| http.request(req) }
        res.is_a?(Net::HTTPSuccess) ? (JSON.parse(res.body) rescue true) : (@last_error = "API #{res.code}"; nil)
      rescue => e
        @last_error = e.message; nil
      end

      def api_patch(path, body)
        token = refresh_access_token
        return nil unless token
        uri = URI("#{GRAPH_BASE}#{path}")
        req = Net::HTTP::Patch.new(uri)
        req['Authorization'] = "Bearer #{token}"
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30, open_timeout: 10) { |http| http.request(req) }
        res.is_a?(Net::HTTPSuccess) ? (JSON.parse(res.body) rescue true) : (@last_error = "API #{res.code}"; nil)
      rescue => e
        @last_error = e.message; nil
      end

      def api_delete(path)
        token = refresh_access_token
        return nil unless token
        uri = URI("#{GRAPH_BASE}#{path}")
        req = Net::HTTP::Delete.new(uri)
        req['Authorization'] = "Bearer #{token}"
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30, open_timeout: 10) { |http| http.request(req) }
        res.is_a?(Net::HTTPSuccess) || res.code == '204'
      rescue => e
        @last_error = e.message; false
      end
    end
  end
end
