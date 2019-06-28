require 'libosctl'

include OsCtl::Lib::Utils::Log
include OsCtl::Lib::Utils::System

zfs(:list, '-Hr -o name', "#{$DATASET}/ct").output.split("\n")[1..-1].each do |ds|
  zfs(:set, 'canmount=noauto', ds)
end
