require 'libosctl'
require 'osctld/net_config'
require 'osctld/process_identity'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtOnStart < UserControl::Commands::Base
    handle :ct_on_start

    class NetworkSetupFailed < StandardError; end
    class InitIdentityFailed < StandardError; end

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      init_identity = open_init_identity(ct)

      # Configure the system
      DistConfig.run(ct.run_conf, :start)
      configure_static_network(ct, init_identity)

      Hook.run(ct, :on_start)
      ok
    rescue HookFailed, NetworkSetupFailed, InitIdentityFailed => e
      error(e.message)
    ensure
      init_identity&.close
    end

    protected

    def detect_init_pid(ct)
      pid = positive_pid(ct.run_conf&.init_pid)
      return pid if pid

      positive_pid(ct.refresh_init_pid)
    rescue StandardError => e
      log(:warn, ct, "Unable to detect init PID for start-time network setup: #{e.message}")
      nil
    end

    def open_init_identity(ct)
      init_pid = detect_init_pid(ct)
      return unless init_pid

      ProcessIdentity.new(init_pid, namespaces: %i[net pid])
    rescue SystemCallError, IOError, ArgumentError => e
      raise InitIdentityFailed,
            "unable to resolve current container init identity: #{e.message}"
    end

    def positive_pid(value)
      return unless value.respond_to?(:to_i)

      pid = value.to_i
      pid > 0 ? pid : nil
    end

    def configure_static_network(ct, init_identity)
      return unless ct.can_dist_configure_network?

      net_config = NetConfig.create(ct).export(configured_only: true)
      return if net_config.empty?

      if init_identity.nil?
        raise NetworkSetupFailed, 'network setup failed: container init PID is not available'
      end

      fork_static_network_setup(init_identity, net_config)
    end

    def fork_static_network_setup(init_identity, net_config)
      r, w = IO.pipe

      pid = Process.fork do
        r.close
        msg = nil
        status = 0

        begin
          unless init_identity.alive?
            raise Errno::ESRCH, 'container init process exited'
          end

          NetConfig.setup_in_netns_io(init_identity.namespace(:net), net_config)
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
      return if status.success?

      detail = msg.empty? ? "exited with status #{status.exitstatus}" : msg
      raise NetworkSetupFailed, "network setup failed: #{detail}"
    end
  end
end
