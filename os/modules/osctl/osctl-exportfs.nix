{ config, lib, pkgs, utils, ... }:
with lib;
let
  cfg = config.osctl.exportfs;
  nfsCfg = config.services.nfs;

  waitForRpcBind = ''
    until ${pkgs.rpcbind}/bin/rpcinfo -s > /dev/null 2>&1 ; do
      echo "Waiting for rpcbind to start"
      sleep 1
    done
  '';
in {
  ###### interface

  options = {
    osctl.exportfs = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable osctl-exportfs integration.
        '';
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

  config = mkIf cfg.enable {
    runit.services.osctl-exportfs = {
      run = ''
        statedir=/run/osctl/exportfs
        tplrunitdir=$statedir/template/runit
        nfsdir=/var/lib/nfs

        mkdir -p "$statedir"
        chmod 0750 "$statedir"
        mkdir -p "$statedir/rootfs"
        mkdir -p "$statedir/runsvdir"
        mkdir -p "$statedir/servers"
        mkdir -p "$tplrunitdir"
        mkdir -p "$tplrunitdir/runsvdir"
        mkdir -p "$tplrunitdir/runsvdir/"{nfsd,rpcbind,statd}

        function mkScript {
          local name="$1"
          echo "#!${pkgs.bash}/bin/bash" > "$name"
          cat >> "$name"
          chmod +x "$name"
        }

        mkScript "$tplrunitdir/1" <<EOF
        mkdir -p "$nfsdir/rpc_pipefs"
        mount -t rpc_pipefs rpc_pipefs "$nfsdir/rpc_pipefs" -o defaults || exit 1
        mount -t nfsd nfsd /proc/fs/nfsd || exit 1
        EOF

        mkScript "$tplrunitdir/2" <<EOF
        exec runsvdir "$statedir/current-server/runit/runsvdir"
        EOF

        mkScript "$tplrunitdir/3" <<EOF
        exit 0
        EOF

        mkScript "$tplrunitdir/runsvdir/rpcbind/run" <<EOF
        exec ${pkgs.rpcbind}/bin/rpcbind -f
        EOF

        mkScript "$tplrunitdir/runsvdir/nfsd/run" <<EOF
        ${waitForRpcBind}

        exportfs -ra &> /dev/null || exit 1
        ${pkgs.nfs-utils}/bin/rpc.nfsd -- ${toString nfsCfg.server.nproc}
        exec ${pkgs.nfs-utils}/bin/rpc.mountd \
          --foreground \
          ${optionalString (cfg.mountdPort != null) "--port ${toString cfg.mountdPort}"}
        EOF

        mkScript "$tplrunitdir/runsvdir/statd/run" <<EOF
        ${waitForRpcBind}

        mkdir -p "$nfsdir/"{sm,sm.bak}
        exec ${pkgs.nfs-utils}/bin/rpc.statd \
          --foreground \
          ${optionalString (cfg.statdPort != null) "--port ${toString cfg.statdPort}"} \
          ${optionalString (cfg.lockdPort != null) "--nlm-port ${toString cfg.lockdPort}"} \
          ${optionalString (cfg.lockdPort != null) "--nlm-udp-port ${toString cfg.lockdPort}"}
        EOF

        exec runsvdir "$statedir/runsvdir"
      '';
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };

    environment.systemPackages = with pkgs; [
      osctl-exportfs
    ];
  };
}
