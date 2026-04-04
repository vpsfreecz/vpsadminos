# frozen_string_literal: true

require 'fileutils'

module FsHelpers
  def mkdir_p(path)
    FileUtils.mkdir_p(path)
  end

  def write_yaml_file(path, data)
    mkdir_p(File.dirname(path))
    File.write(path, YAML.dump(data))
  end

  def read_yaml_file(path)
    YAML.load_file(path)
  end
end

RSpec.configure do |config|
  config.include FsHelpers
end
