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

      exports = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Contents of the /etc/exports file.  See
          <citerefentry><refentrytitle>exports</refentrytitle>
          <manvolnum>5</manvolnum></citerefentry> for the format.
        '';
      };

      nfsd = {
        nproc = mkOption {
          type = types.ints.positive;
          default = 8;
          description = ''
            Specify the number of NFS server threads. By default, eight threads
            are started. However, for optimum performance several threads should
            be used.
          '';
        };

        port = mkOption {
          type = types.int;
          default = 2049;
          description = ''
            Configure port for rpc.nfsd, useful if server is behind firewall.
          '';
        };

        tcp = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Instruct the kernel nfs server to open and listen on a TCP socket.
          '';
        };

        udp = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Instruct the kernel nfs server to open and listen on a UDP socket.
          '';
        };

        allowedVersions = mkOption {
          type = types.listOf (types.enum [ "2" "3" "4" "4.0" "4.1" "4.2" ]);
          default = [];
          description = ''
            This  option can be used to request that rpc.nfsd offer certain
            versions of NFS. The current version of rpc.nfsd can support major
            NFS versions 2,3,4 and the minor versions 4.0, 4.1 and 4.2.
          '';
        };

        disallowedVersions = mkOption {
          type = types.listOf (types.enum [ "2" "3" "4" "4.0" "4.1" "4.2" ]);
          default = [];
          description = ''
            This  option can be used to request that rpc.nfsd does not offer
            certain versions of NFS. The current version of rpc.nfsd can support
            major NFS versions 2,3,4 and the minor versions 4.0, 4.1 and 4.2.
          '';
        };

        syslog = mkOption {
          type = types.bool;
          default = false;
          description = ''
            By default, rpc.nfsd logs error messages (and debug messages, if
            enabled) to stderr. This option makes rpc.nfsd log these messages to
            syslog instead. Note that errors encountered during option processing
            will still be logged to stderr regardless of this option.
          '';
        };
      };

      mountdPort = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 4002;
        description = ''
          Use fixed port for rpc.mountd, useful if server is behind firewall.
        '';
      };

      lockdPort = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 4001;
        description = ''
          Use a fixed port for the NFS lock manager kernel module
          (<literal>lockd/nlockmgr</literal>).  This is useful if the
          NFS server is behind a firewall.
        '';
      };

      statdPort = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 4000;
        description = ''
          Use a fixed port for <command>rpc.statd</command>. This is
          useful if the NFS server is behind a firewall.
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf ((config.boot.supportedFilesystems.nfs or false) || (config.boot.supportedFilesystems.nfs4 or false)) {

      services.rpcbind.enable = true;

      environment.systemPackages = [ pkgs.nfs-utils ];

      runit.services.statd.run = ''
        ensureServiceStarted rpcbind
        ${waitForRpcBind}
        mkdir -p ${nfsStateDir}/{sm,sm.bak}
        exec ${pkgs.nfs-utils}/bin/rpc.statd \
          --foreground \
          ${optionalString (cfg.server.statdPort != null) "--port ${toString cfg.server.statdPort}"} \
          ${optionalString (cfg.server.lockdPort != null) "--nlm-port ${toString cfg.server.lockdPort}"} \
          ${optionalString (cfg.server.lockdPort != null) "--nlm-udp-port ${toString cfg.server.lockdPort}"}
      '';
    })

    (mkIf cfg.server.enable {

      boot.supportedFilesystems = { nfs = true; };

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

        ${pkgs.nfs-utils}/bin/rpc.nfsd \
          --port ${toString cfg.server.nfsd.port} \
          ${if cfg.server.nfsd.tcp then "--tcp" else "--no-tcp"} \
          ${if cfg.server.nfsd.udp then "--udp" else "--no-udp"} \
          ${optionalString (cfg.server.nfsd.allowedVersions != []) "--nfs-version ${concatStringsSep "," cfg.server.nfsd.allowedVersions}"} \
          ${optionalString (cfg.server.nfsd.disallowedVersions != []) "--no-nfs-version ${concatStringsSep "," cfg.server.nfsd.allowedVersions}"} \
          ${optionalString cfg.server.nfsd.syslog "--syslog"} \
          -- ${toString cfg.server.nfsd.nproc}

        exec ${pkgs.nfs-utils}/bin/rpc.mountd \
          --foreground \
          ${optionalString (cfg.server.mountdPort != null) "--port ${toString cfg.server.mountdPort}"} \
          &> /dev/null
      '';
    })
  ];
}

