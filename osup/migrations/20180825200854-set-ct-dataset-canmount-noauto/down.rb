require 'libosctl'

include OsCtl::Lib::Utils::Log
include OsCtl::Lib::Utils::System

toplevel = zfs(:get, '-Hp -o value org.vpsadminos.osctl:dataset', $POOL)[:output].strip
toplevel = $POOL if toplevel == '-'

zfs(:list, '-Hr -o name', "#{toplevel}/ct")[:output].split("\n")[1..-1].each do |ds|
  zfs(:set, 'canmount=on', ds)
end
