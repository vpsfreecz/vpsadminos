require 'libosctl'

include OsCtl::Lib::Utils::Log
include OsCtl::Lib::Utils::System

conf_dir = zfs(:get, '-Hp -o value mountpoint', File.join($POOL, 'conf'))[:output].strip

Dir.glob(File.join(conf_dir, 'user', '*.yml')).each do |f|
  cfg = YAML.load_file(f)
  cfg['type'] = 'static'
  File.write(f, YAML.dump(cfg))
end
