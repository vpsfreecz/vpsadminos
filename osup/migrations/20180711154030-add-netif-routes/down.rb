require 'libosctl'
require 'yaml'

include OsCtl::Lib::Utils::Log
include OsCtl::Lib::Utils::System
include OsCtl::Lib::Utils::File

conf_dir = zfs(:get, '-Hp -o value mountpoint', File.join($POOL, 'conf')).output.strip
conf_ct = File.join(conf_dir, 'ct')

Dir.glob(File.join(conf_ct, '*.yml')).each do |cfg_path|
  ctid = File.basename(cfg_path)[0..-5]
  puts "CT #{ctid}"

  cfg = YAML.load_file(cfg_path)
  next unless cfg['net_interfaces']

  cfg['net_interfaces'].each do |netif|
    next if netif['type'] != 'routed' || !netif['routes']

    puts "  netif #{netif['name']}"
    netif.delete('routes')
  end

  regenerate_file(cfg_path, 0400) do |new|
    new.write(YAML.dump(cfg))
  end
end
