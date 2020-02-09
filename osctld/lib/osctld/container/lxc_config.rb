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
        desc: 'LXC config',
        user: 0,
        group: 0,
        mode: 0644
      )
    end

    def configure
      exclusively do
        ErbTemplate.render_to('ct/config', {
          distribution: ct.distribution,
          version: ct.version,
          ct: ct,
          cgparams: ct.cgparams,
          prlimits: ct.prlimits,
          netifs: ct.netifs,
          mounts: ct.mounts.all_entries,
        }, config_path)
      end
    end

    alias_method :configure_base, :configure
    alias_method :configure_cgparams, :configure
    alias_method :configure_prlimits, :configure
    alias_method :configure_network, :configure
    alias_method :configure_mounts, :configure

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
