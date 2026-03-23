# Main Timely module
require 'fileutils'
require 'yaml'
require 'json'
require 'sqlite3'
require 'time'
require 'date'

# Create Timely home directory structure
TIMELY_HOME = File.expand_path('~/.timely')
TIMELY_DB = File.join(TIMELY_HOME, 'timely.db')
TIMELY_CONFIG = File.join(TIMELY_HOME, 'config.yml')
TIMELY_LOGS = File.join(TIMELY_HOME, 'logs')
TIMELY_CACHE = File.join(TIMELY_HOME, 'cache')

# Create directory structure
[TIMELY_HOME, TIMELY_LOGS, TIMELY_CACHE].each do |dir|
  FileUtils.mkdir_p(dir)
end

# Load all components
require_relative 'timely/version'

# Core infrastructure
require_relative 'timely/database'
require_relative 'timely/config'
require_relative 'timely/event'
require_relative 'timely/astronomy'
require_relative 'timely/weather'

# Sources and sync
require_relative 'timely/sources/ics_file'
require_relative 'timely/sources/google'
require_relative 'timely/sync/poller'

# UI components
require_relative 'timely/ui/panes'
require_relative 'timely/ui/views/month'
require_relative 'timely/ui/application'

module Timely
  class Error < StandardError; end
end
