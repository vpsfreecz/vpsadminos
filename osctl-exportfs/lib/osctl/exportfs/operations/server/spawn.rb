require 'fileutils'
require 'libosctl'
require 'osctl/exportfs/operations/base'
require 'securerandom'

module OsCtl::ExportFS
  # Start a NFS server and wait for it to terminate
  #
  # Networking is realized using a pair of veth interfaces -- one on the host
  # and one in the container. IP addresses of the NFS server is routed to
  # the container, the container routes outbound traffic through osrtr0.
  #
  # The container has its own mount, network, UTS and PID namespace, only the
  # user namespace is shared. The rootfs is a tmpfs and all required directories
  # and files are bind-mounted from the host, i.e. the entire /nix/store,
  # static files in /etc and so on. All other mounts are cleared.
  class Operations::Server::Spawn < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @param name [String]
    def initialize(name)
      @server = Server.new(name)
      @cfg = server.open_config
      @cgroup = CGroup.new('systemd', 'osctl/exportfs/servers')
    end

    def execute
      server.synchronize do
        fail 'server is already running' if server.running?
        fail 'provide server address' if cfg.address.nil?
      end

      @rand_id = SecureRandom.hex(3)
      netns = rand_id
      @netif_host = cfg.netif
      @netif_ns = "nfsns-#{netif_ns}"

      cgroup.create(server.name)
      cgroup.enter(server.name)

      cg_payload = File.join(server.name, 'payload')
      cgroup.create(cg_payload)

      # The parent remains in the host namespace, where as the child unshares
      # namespaces
      main = Process.fork do
        cgroup.enter(cg_payload)
        Process.setpgrp

        # Create a new network namespace and a veth pair
        syscmd("ip netns add #{netns}")
        syscmd("ip link add #{netif_host} type veth peer name #{netif_ns}")
        syscmd("ip link set #{netif_ns} netns #{netns}")
        syscmd("ip link set #{netif_host} up")
        syscmd("ip route add #{cfg.address}/32 dev #{netif_host}")

        # Remove the named network namespace from the filesystem
        Sys.setns_path("/run/netns/#{netns}", Sys::CLONE_NEWNET)
        Sys.unmount("/run/netns/#{netns}")
        File.unlink("/run/netns/#{netns}")

        # Create new namespaces
        Sys.unshare_ns(
          Sys::CLONE_NEWNS \
          | Sys::CLONE_NEWUTS \
          | Sys::CLONE_NEWIPC \
          | Sys::CLONE_NEWPID
        )

        # Run the server in a forked process, required by PID namespace
        run_server
      end

      # Forward SIGTERM and SIGINT
      %w(TERM INT).each do |sig|
        Signal.trap(sig) do
          Process.kill(sig, main)
        end
      end

      # Wait for the child to terminate and then cleanup
      Process.wait(main)
      File.unlink(server.pid_file)
      syscmd("ip link del #{netif_host}")

      log(:info, 'Killing remaining processes')
      cgroup.kill_all_until_empty(cg_payload)
      cgroup.destroy(cg_payload)
    end

    protected
    attr_reader :server, :cfg, :cgroup, :rand_id, :netif_host, :netif_ns

    def run_server
      main = Process.fork do
        # Mount the new root filesystem
        Sys.mount_tmpfs(RunState::ROOTFS)

        # Add exports that were configured before the server was started
        add_exports

        # Mark all mounts as slave, in case some mounts from the parent namespace
        # are marked as shared, because unmounting them in this namespaces
        # would result in them being unmounted in the parent namespace as well.
        Sys.make_rslave('/')

        # Unmount all unnecessary mounts
        clear_mounts

        # Create necessary directories in the new rootfs
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'bin'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'dev'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'etc/runit'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'proc'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, RunState::DIR))
        File.chmod(0750, File.join(RunState::ROOTFS, RunState::DIR))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, RunState::CURRENT_SERVER))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'nix/store'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'sys'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'var/lib/nfs'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'usr/bin'))

        # Mount /proc, /dev, /sys and /nix/store
        Sys.mount_proc(File.join(RunState::ROOTFS, 'proc'))
        Sys.bind_mount('/dev', File.join(RunState::ROOTFS, 'dev'))
        Sys.bind_mount('/nix/store', File.join(RunState::ROOTFS, 'nix/store'))
        Sys.bind_mount('/sys', File.join(RunState::ROOTFS, 'sys'))

        # Symlinks for $PATH and /etc
        File.symlink(
          File.readlink('/run/current-system'),
          File.join(RunState::ROOTFS, 'run/current-system')
        )
        File.symlink(
          File.readlink('/bin/sh'),
          File.join(RunState::ROOTFS, 'bin/sh')
        )
        File.symlink(
          File.readlink('/usr/bin/env'),
          File.join(RunState::ROOTFS, 'usr/bin/env')
        )
        File.symlink(
          File.readlink('/etc/static'),
          File.join(RunState::ROOTFS, 'etc/static')
        )

        %w(group passwd shadow).each do |v|
          dst = File.join(RunState::ROOTFS, 'etc', v)
          File.open(dst, 'w'){}
          Sys.bind_mount(File.join('/etc', v), dst)
        end

        # Mount the current server directory, we need rbind to also mount the
        # shared directory
        Sys.rbind_mount(
          server.dir,
          File.join(RunState::ROOTFS, RunState::CURRENT_SERVER)
        )

        # Switch to the new rootfs
        Dir.chdir(RunState::ROOTFS)
        Dir.mkdir('old-root')
        syscmd("pivot_root . old-root")
        Sys.chroot('.')
        Sys.unmount_lazy('/old-root')
        Dir.rmdir('/old-root')
        server.enter_ns

        # Mount files and directories from the server directory to the system
        # where they're expected
        Sys.bind_mount(server.nfs_state, '/var/lib/nfs')
        File.symlink('/run', '/var/run')
        %w(hosts localtime services).each do |v|
          File.symlink("/etc/static/#{v}", "/etc/#{v}")
        end
        File.symlink(server.exports_file, '/etc/exports')

        # Generate runit scripts and services
        Operations::Runit::Generate.run(server, cfg)

        # Generate NFS exports
        Operations::Exportfs::Generate.run(server)

        # Configure the network interface
        syscmd('ip link set lo up')
        syscmd("ip link set #{netif_ns} name eth0")
        @netif_ns = 'eth0'
        syscmd("ip link set #{netif_ns} up")
        syscmd("ip addr add #{cfg.address}/32 dev #{netif_ns}")
        syscmd("ip route add 255.255.255.254 dev #{netif_ns}")
        syscmd("ip route add default via 255.255.255.254 dev #{netif_ns}")

        # Instruct runit to exit on SIGCONT
        if File.exist?('/etc/runit/stopit')
          File.chmod(0100, '/etc/runit/stopit')
        else
          File.open('/etc/runit/stopit', 'w', 0100) {}
        end

        puts 'Starting nfsd...'
        Process.exec('runit-init')
      end

      # Save the server's PID file
      File.open(server.pid_file, 'w') { |f| f.write(main.to_s) }

      # Forward SIGTERM and SIGINT
      %w(TERM INT).each do |sig|
        Signal.trap(sig) do
          Process.kill('CONT', main)
        end
      end

      Process.wait(main)
    end

    def clear_mounts
      mounts = []
      whitelist = %W(
        /
        /dev
        /nix/store
        /nix/.overlay-store
        /run
        #{RunState::ROOTFS}
        #{RunState::ROOTFS}/**
        #{RunState::SERVERS}/*/shared
        /run/wrappers
        /sys
        /sys/fs/cgroup
        /sys/fs/cgroup/*
      )

      File.open('/proc/mounts').each_line do |line|
        fs, mountpoint = line.split(' ')

        keep = whitelist.detect do |pattern|
          File.fnmatch?(pattern, mountpoint)
        end

        mounts << mountpoint unless keep
      end

      mounts.sort.reverse_each do |mnt|
        Sys.unmount_lazy(mnt)
      end
    end

    def add_exports
      cfg.exports.each do |ex|
        as = File.join(RunState::ROOTFS, ex.as)
        FileUtils.mkdir_p(as)
        Sys.bind_mount(ex.dir, as)
      end
    end
  end
end
