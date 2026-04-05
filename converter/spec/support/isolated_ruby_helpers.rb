# frozen_string_literal: true

module IsolatedRubyHelpers
  def run_isolated_ruby(script)
    rubylib = [
      File.join(REPO_ROOT, 'converter', 'lib'),
      File.join(REPO_ROOT, 'libosctl', 'lib')
    ].join(File::PATH_SEPARATOR)

    Open3.capture3(
      { 'RUBYLIB' => rubylib },
      'ruby',
      '-e',
      script
    )
  end
end

RSpec.configure do |config|
  config.include IsolatedRubyHelpers
end
