#!/usr/bin/env ruby

require 'digest'
require 'json'
require 'optparse'
require 'tempfile'

module OsCtl
  module Lib; end

  module RtnlMonitor
    class RootManifest
      class InvalidInventory < StandardError; end

      def initialize(cgroup_mount:, max_roots: 1024, proc_root: '/proc', mountinfo: '/proc/self/mountinfo')
        @mount = cgroup_mount
        @max_roots = max_roots
        @proc_root = proc_root
        @mountinfo = mountinfo
      end

      def build(containers, generated_monotonic_ns:)
        validate_mount!
        raise InvalidInventory, 'too many running containers' if containers.length > @max_roots

        roots = containers.map { |ct| root_for(ct) }
        paths = roots.map { |root| root.fetch(:path) }.sort
        identities = roots.map { |root| [root.fetch(:pool), root.fetch(:id)] }
        if identities.uniq.length != identities.length || paths.uniq.length != paths.length
          raise InvalidInventory, 'duplicate container or cgroup root'
        end

        paths.each do |path|
          parent = File.dirname(path)
          until parent == '.'
            raise InvalidInventory, 'overlapping cgroup roots' if paths.include?(parent)

            parent = File.dirname(parent)
          end
        end

        {
          schema: 1,
          generated_monotonic_ns:,
          cgroup_mount: @mount,
          roots:
        }
      end

      # A second daemon response closes ordinary stop/start and group-move races.
      def self.same_inventory?(before, after)
        identity = lambda do |rows|
          rows.map { |ct| ct.values_at(:pool, :id, :user, :group, :state, :init_pid, :group_path) }.sort
        end
        identity.call(before) == identity.call(after)
      end

      def self.publish(path, manifest, owner: 0)
        parent = File.dirname(path)
        st = File.lstat(parent)
        unless st.directory? && st.uid == owner && (st.mode & 0o777) == 0o700
          raise InvalidInventory, 'manifest directory must be private and owned by root'
        end

        if File.exist?(path) || File.symlink?(path)
          st = File.lstat(path)
          unless st.file? && st.uid == owner && (st.mode & 0o777) == 0o600
            raise InvalidInventory, 'existing manifest must be a root-only regular file'
          end
        end

        Tempfile.create(['.roots-', '.json'], parent) do |file|
          file.chmod(0o600)
          file.write(JSON.generate(manifest))
          file.write("\n")
          file.flush
          file.fsync
          File.rename(file.path, path)
        end
      end

      protected

      def validate_mount!
        unless @mount.start_with?('/') && @mount.bytesize < 4096 && File.realpath(@mount) == @mount
          raise InvalidInventory, 'invalid cgroup mount path'
        end

        mounts = File.readlines(@mountinfo).map(&:split)
        entry = mounts.find { |fields| unescape(fields[4]) == @mount }
        return if entry && entry[3] == '/' && entry[entry.index('-').to_i + 1] == 'cgroup2'

        raise InvalidInventory, 'selected mount is not a cgroup-v2 hierarchy root'
      end

      def unescape(value)
        value.gsub(/\\([0-7]{3})/) { ::Regexp.last_match(1).to_i(8).chr }
      end

      def root_for(ct)
        pool = identifier(ct.fetch(:pool))
        id = identifier(ct.fetch(:id))
        user = identifier(ct.fetch(:user))
        raise InvalidInventory, 'container is no longer running' unless ct[:state] == 'running'

        exported = ct.fetch(:group_path)
        unless exported.is_a?(String) && exported.end_with?("/user.#{user}/ct.#{id}/user-owned")
          raise InvalidInventory, 'inventory does not export the expected container cgroup'
        end

        path = exported.delete_suffix('/user-owned')
        if path.bytesize >= 4096 || path.start_with?('/') || path.split('/').any? { |p| ['', '.', '..'].include?(p) }
          raise InvalidInventory, 'invalid relative container cgroup root'
        end

        full_path = File.join(@mount, path)
        raise InvalidInventory, 'container root escapes selected hierarchy' unless File.realpath(full_path) == full_path

        pid = ct.fetch(:init_pid)
        raise InvalidInventory, 'running container has no valid init PID' unless pid.is_a?(Integer) && pid > 0

        root_before = File.stat(full_path)
        raise InvalidInventory, 'container root is not a directory' unless root_before.directory?

        first = init_identity(pid, path)
        second = init_identity(pid, path)
        root_after = File.stat(full_path)
        unless first == second && [root_before.dev, root_before.ino] == [root_after.dev, root_after.ino]
          raise InvalidInventory, 'container init or root changed during inventory'
        end

        # These stat values are token ingredients only, never a claimed BPF CGID.
        token = Digest::SHA256.hexdigest(JSON.generate([pool, id, path, pid, first[0], root_after.dev, root_after.ino]))
        { pool:, id:, path:, run_token: token }
      rescue KeyError, Errno::ENOENT, Errno::ESRCH => e
        raise InvalidInventory, "incomplete or changing container inventory: #{e.class}"
      end

      def identifier(value)
        unless value.is_a?(String) && value.bytesize.between?(1, 127) && !value.match?(%r{[\x00-\x1f\x7f/]})
          raise InvalidInventory, 'invalid inventory identifier'
        end

        value
      end

      def init_identity(pid, root)
        stat = File.read(File.join(@proc_root, pid.to_s, 'stat'))
        closing = stat.rindex(')')
        raise InvalidInventory, 'invalid container init stat record' unless closing

        fields = stat[closing + 1..].split
        unless stat.split.first == pid.to_s && fields.length >= 20 && !%w[Z X x].include?(fields[0])
          raise InvalidInventory, 'invalid or exited container init'
        end

        start = Integer(fields[19], 10)
        memberships = File.readlines(File.join(@proc_root, pid.to_s, 'cgroup')).map(&:strip)
        membership = memberships.find { |line| line.start_with?('0::/') }&.delete_prefix('0::/')
        unless membership && membership.start_with?("#{root}/")
          raise InvalidInventory, 'container init is outside its inventory root'
        end

        [start, membership]
      rescue ArgumentError
        raise InvalidInventory, 'invalid container init start identity'
      end
    end

    def self.run_adapter(argv)
      options = { output: '/run/osctl-rtnl-monitor/roots.json', refresh_ms: 5000, max_roots: 1024 }
      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: osctl-rtnl-monitor-roots [options]'
        opts.on('--output PATH', 'Atomic inventory file (mode 0600)') { |v| options[:output] = v }
        opts.on('--refresh-ms N', Integer, 'Refresh interval in milliseconds (default 5000)') { |v| options[:refresh_ms] = v }
        opts.on('--max-roots N', Integer, 'Maximum running container roots (default 1024)') { |v| options[:max_roots] = v }
        opts.on('--once', 'Publish one consistent inventory and exit') { options[:once] = true }
        opts.on('--help', 'Show this help without reading inventory') do
          puts opts
          return 0
        end
      end
      parser.parse!(argv)
      unless argv.empty? && options[:refresh_ms].between?(100, 60_000) && options[:max_roots].between?(1, 1024)
        raise ArgumentError, 'invalid adapter arguments'
      end
      raise ArgumentError, 'root privilege is required' unless Process.euid == 0

      require 'osctl/client'
      require 'libosctl/cgroup'
      raise ArgumentError, 'cgroup v2 is required' unless OsCtl::Lib::CGroup.v2?

      reader = RootManifest.new(cgroup_mount: OsCtl::Lib::CGroup.fs, max_roots: options[:max_roots])
      Signal.trap('TERM') { raise Interrupt }
      Signal.trap('INT') { raise Interrupt }
      inventory = lambda do
        client = OsCtl::Client.new
        begin
          client.open
          client.cmd_data!(:ct_list, state: ['running'], read_hostname: false)
        ensure
          client.close if client.socket
        end
      end

      loop do
        begin
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
          before = inventory.call
          manifest = reader.build(before, generated_monotonic_ns: started)
          unless RootManifest.same_inventory?(before, inventory.call)
            raise RootManifest::InvalidInventory, 'daemon inventory changed during refresh'
          end

          RootManifest.publish(options[:output], manifest)
          return 0 if options[:once]
        rescue StandardError => e
          warn JSON.generate(schema: 1, type: 'status', reason: 'inventory_refresh_failed', message: e.message[0, 256])
          return 1 if options[:once]
        end
        sleep(options[:refresh_ms] / 1000.0)
      end
    rescue Interrupt
      0
    rescue OptionParser::ParseError, ArgumentError => e
      warn e.message
      1
    end
  end
end

exit(OsCtl::RtnlMonitor.run_adapter(ARGV)) if $0 == __FILE__
