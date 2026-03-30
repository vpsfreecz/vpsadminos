# frozen_string_literal: true

module FakeProcHelpers
  def proc_dir(root, pid)
    path = File.join(root, pid.to_s)
    FileUtils.mkdir_p(path)
    path
  end

  def write_proc_file(root, pid, relative_path, contents)
    path = File.join(proc_dir(root, pid), relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end
end

RSpec.configure do |config|
  config.include FakeProcHelpers
end
