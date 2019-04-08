require 'libosctl'

include OsCtl::Lib::Utils::Log
include OsCtl::Lib::Utils::System

zfs(:destroy, '-r', File.join($POOL, 'user'))
