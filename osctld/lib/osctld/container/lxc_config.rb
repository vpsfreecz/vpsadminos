require 'libosctl'
require 'osctld/exceptions'
require 'osctld/lockable'

module OsCtld
  # LXC configuration generator
  class Container::LxcConfig
    include Lockable
    include OsCtl::Lib::Utils::Log

    PROTECTED_RAW_KEYS = %w[
      lxc.cgroup.dir
      lxc.cgroup.cpu.cfs_period_us
      lxc.cgroup.cpu.cfs_quota_us
      lxc.cgroup2.cpu.max
      lxc.include
      lxc.apparmor.profile
      lxc.hook.version
      lxc.hook.pre-start
      lxc.hook.pre-mount
      lxc.hook.mount
      lxc.hook.autodev
      lxc.hook.start-host
      lxc.hook.post-stop
    ].freeze

    def initialize(ct)
      init_lock
      @ct = ct
    end

    def assets(add)
      add.file(
        config_path,
        desc: 'LXC config',
        user: 0,
        group: 0,
        mode: 0o644
      )
    end

    def configure(run_conf: nil)
      exclusively do
        run_conf ||= ct.get_run_conf
        rootfs = run_conf.rootfs

        unless rootfs
          if ct.state == :staged
            log(:warn, ct, 'Skipping LXC config generation: rootfs path is not available')
          else
            ct.state = :error
            log(:warn, ct, 'Unable to generate LXC config: rootfs path is not available')
          end

          next false
        end

        validate_raw_config!
        ct.netifs.each do |netif|
          netif.prepare_run_hooks(run_conf) if netif.respond_to?(:prepare_run_hooks)
        end

        render_opts = {
          distribution: run_conf.distribution,
          version: run_conf.version,
          ct:,
          run_conf:,
          rootfs:,
          cgparams: ct.cgparams,
          prlimits: ct.prlimits,
          netifs: ct.netifs,
          mounts: ct.mounts.all_entries,
          raw: ct.raw_configs.lxc
        }

        ErbTemplate.render_to('ct/config', render_opts, run_config_path(run_conf))

        active_run_id = ct.lifecycle.active_run_id
        if active_run_id.nil? || active_run_id == run_conf.run_id
          ErbTemplate.render_to('ct/config', render_opts, config_path)
        end

        true
      end
    end

    alias configure_base configure
    alias configure_cgparams configure
    alias configure_prlimits configure
    alias configure_network configure
    alias configure_mounts configure

    def config_path
      File.join(ct.lxc_dir, 'config')
    end

    def run_config_path(run_conf)
      File.join(ct.lxc_dir, "config.#{run_conf.run_id.key}")
    end

    def remove_run_hooks(run_conf)
      ct.netifs.each do |netif|
        netif.remove_run_hooks(run_conf) if netif.respond_to?(:remove_run_hooks)
      end
    end

    def dup(new_ct)
      ret = super()
      ret.init_lock
      ret.instance_variable_set('@ct', new_ct)
      ret
    end

    protected

    attr_reader :ct

    def validate_raw_config!
      raw = ct.raw_configs.lxc
      return unless raw

      raw.each_line do |line|
        key = line.split('=', 2).first&.strip
        next unless key
        next unless protected_raw_key?(key)

        raise ConfigError, "raw LXC key '#{key}' is managed by osctld"
      end
    end

    def protected_raw_key?(key)
      PROTECTED_RAW_KEYS.include?(key) || key.start_with?('lxc.cgroup.dir.')
    end
  end
end
