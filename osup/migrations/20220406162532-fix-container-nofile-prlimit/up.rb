require 'libosctl'
require 'yaml'

include OsCtl::Lib::Utils::Log
include OsCtl::Lib::Utils::System
include OsCtl::Lib::Utils::File

conf_dir = zfs(:get, '-Hp -o value mountpoint', File.join($DATASET, 'conf')).output.strip
conf_ct = File.join(conf_dir, 'ct')

Dir.glob(File.join(conf_ct, '*.yml')).each do |cfg_path|
  ctid = File.basename(cfg_path)[0..-5]
  puts "CT #{ctid}"

  cfg = YAML.load_file(cfg_path)
  prlimits = cfg['prlimits']
  next if prlimits.nil? || !prlimits.has_key?(:nofile)

  if prlimits.has_key?('nofile')
    prlimits.delete(:nofile)
  else
    prlimits['nofile'] = prlimits[:nofile]
    prlimits.delete(:nofile)
  end

  regenerate_file(cfg_path, 0400) do |new|
    new.write(YAML.dump(cfg))
  end
end
