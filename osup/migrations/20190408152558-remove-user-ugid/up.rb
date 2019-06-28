require 'libosctl'

include OsCtl::Lib::Utils::Log
include OsCtl::Lib::Utils::System

zfs(:create, '-p', File.join($DATASET, 'migration'))

mig_dir = File.join(
  zfs(:get, '-Hp -o value mountpoint', File.join($DATASET, 'migration')).output.strip,
  $MIGRATION_ID.to_s
)
Dir.mkdir(mig_dir)

conf_dir = zfs(:get, '-Hp -o value mountpoint', File.join($DATASET, 'conf')).output.strip
ugid_map = {}

Dir.glob(File.join(conf_dir, 'user', '*.yml')).each do |f|
  name = File.basename(f)[0..(('.yml'.length+1) * -1)]
  cfg = YAML.load_file(f)
  ugid_map[name] = cfg['ugid']
  cfg.delete('ugid')
  File.write(f, YAML.dump(cfg))
end

File.write(
  File.join(mig_dir, 'user_ugids.yml'),
  YAML.dump(ugid_map)
)
