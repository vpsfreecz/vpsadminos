# frozen_string_literal: true

require 'fileutils'
require 'libosctl/config_file'

module ConfigHelpers
  def load_yaml_file(path)
    OsCtl::Lib::ConfigFile.load_yaml_file(path)
  end

  def dump_yaml(hash)
    OsCtl::Lib::ConfigFile.dump_yaml(hash)
  end

  def write_yaml_file(path, hash)
    File.write(path, dump_yaml(hash))
  end

  def prepare_pool_conf_dirs(pool, *entries)
    entries.each do |entry|
      FileUtils.mkdir_p(File.join(pool.conf_path, entry))
    end
  end
end

RSpec.configure do |config|
  config.include ConfigHelpers
end
