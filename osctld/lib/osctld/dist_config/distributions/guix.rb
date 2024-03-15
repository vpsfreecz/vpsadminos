require 'osctld/dist_config/distributions/base'

module OsCtld
  class DistConfig::Distributions::Guix < DistConfig::Distributions::Base
    distribution :guix

    class Configurator < DistConfig::Configurator
      def set_hostname(_new_hostname, old_hostname: nil)
        log(:warn, 'Unable to apply hostname to Guix System container')
      end

      def network(netifs)
        tpl_base = 'dist_config/network/guix'

        %w[add del].each do |operation|
          cmds = netifs.map do |netif|
            OsCtld::ErbTemplate.render(
              File.join(tpl_base, netif.type.to_s),
              { netif:, op: operation }
            )
          end

          writable?(File.join(rootfs, "ifcfg.#{operation}")) do |path|
            File.write(path, cmds.join("\n"))
          end
        end
      end

      protected

      def network_class
        nil
      end
    end

    def stop(opts)
      return super unless %i[stop shutdown].include?(opts[:mode])

      wait_until = Time.now + opts[:timeout]
      stopped = false
      event_queue = Eventd.subscribe

      # Shepherd gets stuck when it is sent a signal, so shut it down only using
      # halt.
      halt_thread = Thread.new do
        ContainerControl::Commands::StopByHalt.run!(
          ct,
          message: opts[:message]
        )
      rescue ContainerControl::Error => e
        log(:warn, ct, "Unable to gracefully shutdown shepherd: #{e.message}")
      end

      loop do
        unless ct.running?
          stopped = true
          break
        end

        timeout = wait_until - Time.now
        break if timeout < 0

        event = event_queue.pop(timeout:)
        break if event.nil?

        # Ignore irrelevant events
        next if event.type != :state \
                || event.opts[:pool] != ct.pool.name \
                || event.opts[:id] != ct.id

        if event.opts[:state] == :stopped
          stopped = true
          break
        end
      end

      Eventd.unsubscribe(event_queue)

      if !stopped && opts[:mode] != :shutdown
        log(:debug, ct, 'Timeout while waiting for graceful shutdown, killing the container')
        super(opts.merge(mode: :kill, message: nil))
      elsif ct.running?
        halt_thread.terminate
        raise ContainerControl::Error, 'Timeout while waiting for halt'
      end

      halt_thread.join
    end

    def passwd(opts)
      # Without the -c switch, the password is not set (bug?)
      ret = ct_syscmd(
        ct,
        %w[chpasswd -c SHA512],
        stdin: "#{opts[:user]}:#{opts[:password]}\n",
        run: true,
        valid_rcs: :all
      )

      return true if ret.success?

      log(:warn, ct, "Unable to set password: #{ret.output}")
    end

    def bin_path(_opts)
      with_rootfs do
        File.realpath('/var/guix/profiles/system/profile/bin')
      rescue Errno::ENOENT
        '/bin'
      end
    end
  end
end
