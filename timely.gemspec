require_relative 'lib/timely/version'

Gem::Specification.new do |spec|
  spec.name          = 'timely-calendar'
  spec.version       = Timely::VERSION
  spec.authors       = ['Geir Isene', 'Claude Code']
  spec.email         = ['g@isene.com']

  spec.summary       = 'Terminal Calendar - companion to Heathrow'
  spec.description   = 'A unified TUI calendar with Google Calendar and Outlook/365 integration, moon phases, weather, astronomy, desktop notifications, and Heathrow messaging handoff. Built on rcurses.'
  spec.homepage      = 'https://github.com/isene/timely'
  spec.license       = 'Unlicense'

  spec.required_ruby_version = '>= 2.7.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/isene/timely'

  # Specify which files should be added to the gem
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.match(%r{\A(?:test|spec|features)/})
    end
  end

  spec.bindir        = 'bin'
  spec.executables   = ['timely']
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_runtime_dependency 'rcurses', '~> 7.0'
  spec.add_runtime_dependency 'sqlite3', '>= 1.4'
end
