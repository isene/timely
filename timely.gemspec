require_relative 'lib/timely/version'

Gem::Specification.new do |spec|
  spec.name          = 'timely'
  spec.version       = Timely::VERSION
  spec.authors       = ['Geir Isene', 'Claude Code']
  spec.email         = ['g@isene.com']

  spec.summary       = 'Terminal Calendar'
  spec.description   = 'A TUI calendar application built on rcurses. View and manage your calendar from the terminal with month, week, and day views.'
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
  spec.add_runtime_dependency 'rcurses', '>= 5.0'
  spec.add_runtime_dependency 'sqlite3', '>= 1.4'
end
