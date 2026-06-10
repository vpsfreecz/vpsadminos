require 'libosctl'
require 'osctld/lockable'

module OsCtld
  # LXC configuration generator
  class Container::LxcConfig
    include Lockable
    include OsCtl::Lib::Utils::Log

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

    def configure
      exclusively do
        run_conf = ct.get_run_conf
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

        ErbTemplate.render_to('ct/config', {
          distribution: run_conf.distribution,
          version: run_conf.version,
          ct:,
          rootfs:,
          cgparams: ct.cgparams,
          prlimits: ct.prlimits,
          netifs: ct.netifs,
          mounts: ct.mounts.all_entries,
          raw: ct.raw_configs.lxc
        }, config_path)
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

    def dup(new_ct)
      ret = super()
      ret.init_lock
      ret.instance_variable_set('@ct', new_ct)
      ret
    end

    protected

    attr_reader :ct
  end
end
