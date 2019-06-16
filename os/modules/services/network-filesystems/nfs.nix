{ config, lib, pkgs, utils, ... }:

with utils;
with lib;

let
  cfg = config.services.nfs;
  nfsStateDir = "/var/lib/nfs";
  rpcMountpoint = "${nfsStateDir}/rpc_pipefs";

  exports = pkgs.writeText "exports" cfg.server.exports;

  nfsConfFile = pkgs.writeText "nfs.conf" cfg.extraConfig;

  waitForRpcBind = ''
    until rpcinfo -s > /dev/null 2>&1 ; do
      warn "Waiting for rpcbind to start"
      sleep 1
    done
  '';

in
{

  ###### interface

  options = {
    services.nfs.server = {
      enable = mkEnableOption "Enable NFS server";
      nproc = mkOption {
        type = types.ints.positive;
        default = 8;
        description = ''
          Specify the number of NFS server threads. By default, eight threads are started.
          However, for optimum performance several threads should be used.
        '';
      };

      exports = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Contents of the /etc/exports file.  See
          <citerefentry><refentrytitle>exports</refentrytitle>
          <manvolnum>5</manvolnum></citerefentry> for the format.
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf (any (fs: fs == "nfs" || fs == "nfs4") config.boot.supportedFilesystems) {

      services.rpcbind.enable = true;

      environment.systemPackages = [ pkgs.nfs-utils ];

      runit.services.statd.run = ''
        ensureServiceStarted rpcbind
        ${waitForRpcBind}
        mkdir -p ${nfsStateDir}/{sm,sm.bak}
        exec ${pkgs.nfs-utils}/bin/rpc.statd -F
      '';
    })

    (mkIf cfg.server.enable {

      boot.supportedFilesystems = [ "nfs" ];

      environment.etc."exports".source = exports;

      runit.services.nfsd.run = ''
        ensureServiceStarted rpcbind
        ensureServiceStarted statd
        ${waitForRpcBind}

        mkdir -p ${rpcMountpoint}
        if ! mountpoint -q ${rpcMountpoint}; then
          mount -t rpc_pipefs rpc_pipefs ${rpcMountpoint} -o defaults || exit 1
        fi

        if ! mountpoint -q /proc/fs/nfsd; then
          mount -t nfsd nfsd /proc/fs/nfsd || exit 1
        fi

        exportfs -ra &> /dev/null || exit 1
        ${pkgs.nfs-utils}/bin/rpc.nfsd -- ${toString cfg.server.nproc}
        exec ${pkgs.nfs-utils}/bin/rpc.mountd --foreground &> /dev/null
      '';
    })
  ];
}

