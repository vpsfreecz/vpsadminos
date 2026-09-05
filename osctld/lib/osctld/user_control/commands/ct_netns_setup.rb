require 'libosctl'
require 'osctld/container_control/commands/state'
require 'osctld/net_config'
require 'osctld/process_identity'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtNetnsSetup < UserControl::Commands::Base
    handle :ct_netns_setup

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ret = authenticate_run_callback(ct)
      return ret if ret

      init_identity = open_init_identity(ct)
      return error('container init process is not available') unless init_identity

      with_claimed_lifecycle_event(
        ct,
        :netns_setup,
        after: :wrapper_start,
        lifecycle: false
      ) do
        setup_netns(init_identity, NetConfig.create(ct).export)
      end
    rescue ContainerControl::Error, SystemCallError, IOError, ArgumentError => e
      error("unable to resolve current container init identity: #{e.message}")
    ensure
      init_identity&.close
    end

    protected

    def open_init_identity(ct)
      state = ContainerControl::Commands::State.run!(ct)
      init_pid = positive_pid(state.init_pid) if state.respond_to?(:init_pid)
      return unless init_pid

      identity = ProcessIdentity.new(init_pid, namespaces: [:net])

      unless identity.in_cgroup_subtree?(ct.base_cgroup_path)
        identity.close
        raise Errno::EPERM, 'container init process is outside its cgroup'
      end

      lifecycle_identity = authenticated_run_conf&.lifecycle_identity
      unless lifecycle_identity && identity.descendant_of?(lifecycle_identity)
        identity.close
        raise Errno::EPERM, 'container init process is outside its lifecycle'
      end

      identity
    end

    def positive_pid(value)
      return unless value.respond_to?(:to_i)

      pid = value.to_i
      pid if pid > 0
    end

    def setup_netns(init_identity, net_config)
      r, w = IO.pipe

      pid = Process.fork do
        r.close
        msg = nil
        status = 0

        begin
          raise Errno::ESRCH, 'container init process exited' unless init_identity.alive?

          NetConfig.setup_in_netns(init_identity, net_config)
        rescue StandardError => e
          msg = "#{e.class}: #{e.message}"
          status = 1
        ensure
          w.write(msg) if msg
          w.close
        end

        exit!(status)
      end

      w.close
      msg = r.read
      r.close

      _, status = Process.wait2(pid)
      return ok if status.success?

      error(msg.empty? ? "network setup exited with status #{status.exitstatus}" : msg)
    end
  end
end
