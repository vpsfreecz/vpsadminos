require 'osctld/lockable'

module OsCtld
  # LXC configuration generator
  class Container::LxcConfig
    include Lockable

    def initialize(ct)
      init_lock
      @ct = ct
    end

    def assets(add)
      add.file(
        config_path,
        desc: 'LXC base config',
        user: 0,
        group: 0,
        mode: 0644
      )
      add.file(
        config_path('network'),
        desc: 'LXC network config',
        user: 0,
        group: 0,
        mode: 0644
      )
      add.file(
        config_path('cgparams'),
        desc: 'LXC cgroup parameters',
        user: 0,
        group: 0,
        mode: 0644
      )
      add.file(
        config_path('prlimits'),
        desc: 'LXC resource limits',
        user: 0,
        group: 0,
        mode: 0644
      )
      add.file(
        config_path('mounts'),
        desc: 'LXC mounts',
        user: 0,
        group: 0,
        mode: 0644
      )
    end

    def configure
      exclusively do
        configure_base
        configure_cgparams
        configure_prlimits
        configure_network
        configure_mounts
      end
    end

    def configure_base
      exclusively do
        ErbTemplate.render_to('ct/config', {
          distribution: ct.distribution,
          version: ct.version,
          ct: ct,
          config_path: method(:config_path),
        }, config_path)
      end
    end

    def configure_cgparams
      exclusively do
        ErbTemplate.render_to('ct/cgparams', {
          cgparams: ct.cgparams,
        }, config_path('cgparams'))
      end
    end

    def configure_prlimits
      exclusively do
        ErbTemplate.render_to('ct/prlimits', {
          prlimits: ct.prlimits,
        }, config_path('prlimits'))
      end
    end

    def configure_network
      exclusively do
        ErbTemplate.render_to('ct/network', {
          netifs: ct.netifs,
        }, config_path('network'))
      end
    end

    def configure_mounts
      exclusively do
        ErbTemplate.render_to('ct/mounts', {
          mounts: ct.mounts.all_entries,
        }, config_path('mounts'))
      end
    end

    def config_path(cfg = 'config')
      File.join(ct.lxc_dir, cfg.to_s)
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
