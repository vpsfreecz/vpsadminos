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
      @cgroup = Operations::Server::CGroup.new(server)
      @sys = OsCtl::Lib::Sys.new
    end

    def execute
      server.synchronize do
        raise 'server is already running' if server.running?
        raise 'provide server address' if cfg.address.nil?
      end

      @rand_id = SecureRandom.hex(3)
      netns = rand_id
      @netif_host = cfg.netif
      @netif_ns = "nfsns-#{server.name}"

      cgroup.enter_manager

      # The parent remains in the host namespace, where as the child unshares
      # namespaces
      main = Process.fork do
        cgroup.enter_payload
        Process.setpgrp

        # Create a new network namespace and a veth pair
        syscmd("ip netns add #{netns}")
        syscmd("ip link add #{netif_host} type veth peer name #{netif_ns}")
        syscmd("ip link set #{netif_ns} netns #{netns}")
        syscmd("ip link set #{netif_host} up")
        syscmd("ip route add #{cfg.address}/32 dev #{netif_host}")

        # Remove the named network namespace from the filesystem
        sys.setns_path("/run/netns/#{netns}", OsCtl::Lib::Sys::CLONE_NEWNET)
        sys.unmount("/run/netns/#{netns}")
        File.unlink("/run/netns/#{netns}")

        # Create new namespaces
        sys.unshare_ns(
          OsCtl::Lib::Sys::CLONE_NEWNS \
          | OsCtl::Lib::Sys::CLONE_NEWUTS \
          | OsCtl::Lib::Sys::CLONE_NEWIPC \
          | OsCtl::Lib::Sys::CLONE_NEWPID
        )

        # Run the server in a forked process, required by PID namespace
        run_server
      end

      # Forward SIGTERM and SIGINT
      %w[TERM INT].each do |sig|
        Signal.trap(sig) do
          Process.kill(sig, main)
        end
      end

      # Wait for the child to terminate and then cleanup
      Process.wait(main)
      File.unlink(server.pid_file)
      syscmd("ip link del #{netif_host}")

      log(:info, 'Killing remaining processes')
      cgroup.clear_payload
    end

    protected

    attr_reader :server, :cfg, :cgroup, :rand_id, :netif_host, :netif_ns, :sys

    def run_server
      main = Process.fork do
        # Mount the new root filesystem
        sys.mount_tmpfs(RunState::ROOTFS)

        # Add exports that were configured before the server was started
        add_exports

        # Mark all mounts as slave, in case some mounts from the parent namespace
        # are marked as shared, because unmounting them in this namespaces
        # would result in them being unmounted in the parent namespace as well.
        sys.make_rslave('/')

        # Unmount all unnecessary mounts
        clear_mounts

        # Create necessary directories in the new rootfs
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'bin'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'dev'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'etc/runit'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'proc'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, RunState::DIR))
        File.chmod(0o750, File.join(RunState::ROOTFS, RunState::DIR))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, RunState::CURRENT_SERVER))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'nix/store'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'sys'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'var/lib/nfs'))
        FileUtils.mkdir_p(File.join(RunState::ROOTFS, 'usr/bin'))

        # Mount /proc, /dev, /sys and /nix/store
        sys.mount_proc(File.join(RunState::ROOTFS, 'proc'))
        sys.bind_mount('/dev', File.join(RunState::ROOTFS, 'dev'))
        sys.bind_mount('/nix/store', File.join(RunState::ROOTFS, 'nix/store'))
        sys.bind_mount('/sys', File.join(RunState::ROOTFS, 'sys'))

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

        %w[group passwd shadow].each do |v|
          dst = File.join(RunState::ROOTFS, 'etc', v)
          File.open(dst, 'w') {}
          sys.bind_mount(File.join('/etc', v), dst)
        end

        # Mount the current server directory, we need rbind to also mount the
        # shared directory
        sys.rbind_mount(
          server.dir,
          File.join(RunState::ROOTFS, RunState::CURRENT_SERVER)
        )

        # Switch to the new rootfs
        Dir.chdir(RunState::ROOTFS)
        Dir.mkdir('old-root')
        syscmd('pivot_root . old-root')
        sys.chroot('.')
        sys.unmount_lazy('/old-root')
        Dir.rmdir('/old-root')
        server.enter_ns

        # Mount files and directories from the server directory to the system
        # where they're expected
        sys.bind_mount(server.nfs_state, '/var/lib/nfs')
        File.symlink('/run', '/var/run')
        %w[hosts localtime services].each do |v|
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
          File.chmod(0o100, '/etc/runit/stopit')
        else
          File.open('/etc/runit/stopit', 'w', 0o100) {}
        end

        puts 'Starting nfsd...'
        Process.exec('runit-init')
      end

      # Save the server's PID file
      File.write(server.pid_file, main.to_s)

      # Forward SIGTERM and SIGINT
      %w[TERM INT].each do |sig|
        Signal.trap(sig) do
          Process.kill('CONT', main)
        end
      end

      Process.wait(main)
    end

    def clear_mounts
      mounts = []
      whitelist = %W[
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
      ]

      File.open('/proc/mounts').each_line do |line|
        fs, mountpoint = line.split(' ')

        keep = whitelist.detect do |pattern|
          File.fnmatch?(pattern, mountpoint)
        end

        mounts << mountpoint unless keep
      end

      mounts.sort.reverse_each do |mnt|
        sys.unmount_lazy(mnt)
      rescue Errno::ENOENT
        next
      end
    end

    def add_exports
      cfg.exports.group_by_as.each do |dir, as, _exports|
        target_as = File.join(RunState::ROOTFS, as)

        FileUtils.mkdir_p(target_as)
        sys.bind_mount(dir, target_as)
      end
    end
  end
end
