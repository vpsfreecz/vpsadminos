# frozen_string_literal: true

require 'fileutils'

module FakeExporterHelpers
  FakeUser = Struct.new(:name, :config_path, keyword_init: true)
  FakeGroup = Struct.new(:name, :config_path, keyword_init: true)
  FakeHookScript = Struct.new(:abs_path, :rel_path, keyword_init: true)
  FakeContainer = Struct.new(
    :id,
    :rootfs,
    :user,
    :group,
    :dataset,
    :datasets,
    :config_path,
    keyword_init: true
  ) do
    attr_writer :dump_config_value

    def dump_config
      @dump_config_value
    end
  end

  def write_file(dir, relative_path, contents)
    path = File.join(dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  def write_executable(dir, name, body)
    path = File.join(dir, name)
    File.write(path, <<~SH)
      #!/bin/sh
      set -eu
      #{body}
    SH
    File.chmod(0o755, path)
    path
  end
end

RSpec.configure do |config|
  config.include FakeExporterHelpers
end
