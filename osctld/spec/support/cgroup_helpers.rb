# frozen_string_literal: true

require 'fileutils'

module CgroupHelpers
  def write_cgroup_file(root, *parts, content: '')
    path = File.join(root, *parts)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def mkdir_cgroup(root, *parts)
    path = File.join(root, *parts)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'cgroup.procs'), '')
    path
  end
end

RSpec.configure do |config|
  config.include CgroupHelpers
end
