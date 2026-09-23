require 'json'
require 'socket'
require 'io/wait'
require 'osctld/process_identity'
require 'osctld/net_config'

module OsCtld
  module ContainerControl; end

  # A private one-shot channel inherited by exactly one transient helper.
  # The helper can signal readiness, but cannot supply a PID or configuration.
  class ContainerControl::TransientNetwork
    # Bound startup only. User commands may legitimately run indefinitely
    # after the private handshake has completed.
    READY_TIMEOUT = 60

    attr_reader :runner_socket

    def initialize(ct, net_config = NetConfig.create(ct))
      @ct = ct
      @net_config = net_config
      @server_socket, @runner_socket = UNIXSocket.pair
    end

    def serve(runner_identity)
      read_ready(runner_identity)

      raise Errno::ESRCH, 'transient helper exited' unless runner_identity.alive?

      state = ContainerControl::Commands::State.run!(@ct, force: true)
      unless state.state == :running && state.init_pid.to_i > 1
        raise Errno::ESRCH, 'transient LXC init is not running'
      end

      ProcessIdentity.open(state.init_pid, namespaces: %i[net user]) do |identity|
        identity.authenticate!(cgroup_path: @ct.cgroup_path)
        authenticate_ancestry!(identity, runner_identity)
        authenticate_namespaces!(identity)
        apply(identity, runner_identity)
      end

      reply(status: true)
      true
    rescue StandardError => e
      @ct.log(:warn, "transient network setup: #{e.full_message(highlight: false)}") if @ct.respond_to?(:log)
      reply(status: false, message: "transient network setup failed (#{e.class})")
      false
    ensure
      @server_socket.close unless @server_socket.closed?
    end

    def close
      [@server_socket, @runner_socket].each { |io| io.close unless io.closed? }
    end

    protected

    def read_ready(runner_identity)
      expected = "ready\n"
      received = ''
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT

      while received.bytesize < expected.bytesize
        raise Errno::ESRCH, 'transient helper exited' unless runner_identity.alive?

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Errno::ETIMEDOUT, 'transient helper readiness timed out' if remaining <= 0

        chunk = @server_socket.read_nonblock(expected.bytesize - received.bytesize, exception: false)
        case chunk
        when :wait_readable
          @server_socket.wait_readable([remaining, 0.1].min)
        when nil
          raise EOFError, 'transient helper closed readiness channel'
        else
          received << chunk
          raise 'invalid transient network request' unless expected.start_with?(received)
        end
      end
    end

    def reply(**result)
      @server_socket.write("#{result.to_json}\n")
    rescue IOError, SystemCallError
      nil
    end

    # Retain every intermediate /proc entry and pidfd. A process can reparent
    # during exit, so recheck each relation after reaching the pinned helper.
    def authenticate_ancestry!(identity, runner_identity)
      chain = [identity]
      relations = []
      current = identity

      loop do
        raise Errno::ESRCH, 'transient helper exited' unless runner_identity.alive?
        raise Errno::ESRCH, 'transient process exited' unless current.alive?

        parent = parent_pid(current)
        relations << [current, parent]
        break if parent == runner_identity.pid

        if parent <= 1 || chain.any? { |entry| entry.pid == parent }
          raise Errno::EXDEV, 'LXC init is not descended from the transient helper'
        end

        current = ProcessIdentity.open(parent)
        chain << current
      end

      relations.each do |entry, parent|
        unless entry.alive? && parent_pid(entry) == parent
          raise Errno::ESTALE, 'transient process ancestry changed'
        end
      end
      raise Errno::ESRCH, 'transient helper exited' unless runner_identity.alive?
    ensure
      chain&.drop(1)&.each(&:close)
    end

    def parent_pid(identity)
      Integer(identity.read_proc_file('stat').rpartition(') ').last.split.fetch(1))
    end

    def same_namespace?(left, right)
      a = left.stat
      b = right.stat
      a.dev == b.dev && a.ino == b.ino
    end

    def authenticate_namespaces!(identity)
      userns = identity.namespace(:user)
      File.open('/proc/self/ns/user') do |host_userns|
        raise Errno::EPERM, 'transient init is in the host user namespace' if same_namespace?(userns, host_userns)
      end
      owner = OsCtl::Lib::Sys.new.namespace_userns(identity.namespace(:net))
      unless same_namespace?(owner, userns)
        raise Errno::EXDEV, 'network namespace belongs to a different user namespace'
      end

      %i[uid gid].each do |kind|
        expected = @ct.user.public_send(:"#{kind}_map").map(&:to_a).sort
        actual = identity.read_proc_file("#{kind}_map").lines.map { |line| line.split.map { |v| Integer(v) } }.sort
        raise Errno::EXDEV, 'transient init has a foreign ID mapping' unless actual == expected
      end
      ns_pids = identity.read_proc_file('status').lines.find { |line| line.start_with?('NSpid:') }&.split
      unless ns_pids && ns_pids.length > 2 && ns_pids.last == '1'
        raise Errno::EXDEV, 'transient process is not a container PID 1'
      end
    ensure
      owner&.close
    end

    def apply(identity, runner_identity)
      pid = SwitchUser.fork(keep_fds: identity.files + runner_identity.files) do
        identity.authenticate!(cgroup_path: @ct.cgroup_path)
        authenticate_ancestry!(identity, runner_identity)
        authenticate_namespaces!(identity)
        sys = OsCtl::Lib::Sys.new
        Process.groups = []
        # Enter with only the container's authority, not host CAP_NET_ADMIN.
        # pidfd setns also installs coupled syslog/tracing on supported kernels.
        sys.setns_io(identity.pidfd, OsCtl::Lib::Sys::CLONE_NEWUSER | OsCtl::Lib::Sys::CLONE_NEWNET)
        %i[user net].each do |name|
          File.open("/proc/self/ns/#{name}") do |current|
            unless same_namespace?(current, identity.namespace(name))
              raise Errno::ESTALE, 'transient namespaces changed before attachment'
            end
          end
        end
        raise Errno::ESRCH, 'transient init exited' unless identity.alive?

        sys.setresgid(0, 0, 0)
        sys.setresuid(0, 0, 0)
        @net_config.setup
        exit!(true)
      rescue StandardError => e
        warn "transient network setup: #{e.full_message(highlight: false)}"
        exit!
      end
      _, status = Process.wait2(pid)
      raise 'transient network child failed' unless status.success?
    end
  end
end
