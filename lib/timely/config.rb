require 'yaml'
require 'fileutils'

module Timely
  class Config
    attr_accessor :settings

    def initialize(config_path = TIMELY_CONFIG)
      @config_path = config_path
      @settings = load_config
    end

    def load_config
      if File.exist?(@config_path)
        YAML.load_file(@config_path) || create_default_config
      else
        create_default_config
      end
    end

    def create_default_config
      default = {
        'version' => Timely::VERSION,
        'location' => {
          'lat' => 59.9139,
          'lon' => 10.7522
        },
        'timezone' => 'Europe/Oslo',
        'default_view' => 'month',
        'work_hours' => {
          'start' => 8,
          'end' => 17
        },
        'week_starts_on' => 'monday',
        'google' => {
          'safe_dir' => '/home/.safe/mail',
          'sync_interval' => 300
        }
      }
      save_config(default)
      default
    end

    def get(key_path, default = nil)
      keys = key_path.to_s.split('.')
      value = @settings
      keys.each do |key|
        break unless value.is_a?(Hash)
        value = value[key]
      end
      value.nil? ? default : value
    end

    def set(key_path, value)
      keys = key_path.to_s.split('.')
      last_key = keys.pop
      parent = @settings
      keys.each { |k| parent[k] ||= {}; parent = parent[k] }
      parent[last_key] = value
    end

    def save
      save_config
    end

    def reload
      @settings = load_config
    end

    def [](key)
      @settings[key]
    end

    def []=(key, value)
      @settings[key] = value
    end

    private

    def save_config(config = @settings)
      FileUtils.mkdir_p(File.dirname(@config_path))
      File.write(@config_path, config.to_yaml)
    end
  end
end
