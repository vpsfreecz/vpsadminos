# frozen_string_literal: true

module FakeSysfsHelpers
  def write_sysfs_file(root, relative_path, contents)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end
end

RSpec.configure do |config|
  config.include FakeSysfsHelpers
end
