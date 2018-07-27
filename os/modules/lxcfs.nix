{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

{
  ###### interface

  options = {
  };

  ###### implementation

  config = {
   runit.services.lxcfs.run = ''
     mkdir -p /var/lib/lxcfs
     mkdir -p /var/log

     exec 1<&-                     # Close STDOUT file descriptor
     exec 2<&-                     # Close STDERR FD
     exec 1<>/var/log/lxcfs.output # Open STDOUT as file for read and write
     exec 2>&1                     # Redirect STDERR to STDOUT

     exec ${pkgs.lxcfs}/bin/lxcfs -l /var/lib/lxcfs
   '';
  };
}
