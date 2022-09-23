require 'forwardable'

module OsCtld
  class Container::Lxcfs
    extend Forwardable

    # @param ct [Container]
    # @param cfg [Hash]
    def self.load(ct, cfg)
      new(
        ct,
        enable: cfg.fetch('enable', true),
        loadavg: cfg.fetch('loadavg', true),
        cfs: cfg.fetch('cfs', true),
      )
    end

    include Lockable

    # @return [Container]
    attr_reader :ct

    # @return [Boolean]
    attr_reader :enable

    def_delegators :lxcfs, :loadavg, :cfs, :mountpoint

    # @param ct [Container]
    def initialize(ct, enable: true, loadavg: true, cfs: true)
      init_lock
      @ct = ct
      @enable = enable
      @lxcfs = OsCtld::Lxcfs.new(
        "ct.#{ct.ident}",
        uid: ct.root_host_uid,
        gid: ct.root_host_gid,
        loadavg: loadavg,
        cfs: cfs,
      )
    end

    def assets(add)
      add.directory(
        lxcfs.mountroot,
        desc: 'LXCFS directory',
        user: ct.root_host_uid,
        group: ct.root_host_gid,
        mode: 0550,
        optional: true,
      )
      add.directory(
        lxcfs.mountpoint,
        desc: 'LXCFS mountpoint',
        user: 0,
        group: 0,
        mode: 0755,
        optional: true,
      )
    end

    # @raise [Lxcfs::Timeout]
    def ensure_and_wait
      exclusively do
        return unless enable

        lxcfs.ensure_start
      end

      lxcfs.wait(timeout: 20)
    end

    def ensure_stop
      exclusively { lxcfs.ensure_stop }
    end

    def running?
      inclusively { lxcfs.running? }
    end

    def configure(loadavg: true, cfs: true)
      exclusively do
        @enable = true
        lxcfs.configure(loadavg: loadavg, cfs: cfs)
        lxcfs.restart if !ct.running? && lxcfs.running?
      end
    end

    def reconfigure
      exclusively do
        lxcfs.reconfigure if enable
      end
    end

    def chown(user)
      if ct.user != user
        fail 'programming error: expected container user to be changed'
      end

      exclusively do
        lxcfs.chown(ct.root_host_uid, ct.root_host_gid)
      end
    end

    def disable
      exclusively do
        @enable = false
        destroy unless ct.running?
      end
    end

    def ensure_destroy
      exclusively { lxcfs.ensure_destroy }
    end

    def post_mount_params
      inclusively do
        {
          mountpoint: lxcfs.mountpoint,
          mount_files: lxcfs.mount_files,
        }
      end
    end

    def dump
      inclusively do
        {
          'enable' => enable,
          'loadavg' => lxcfs.loadavg,
          'cfs' => lxcfs.cfs,
        }
      end
    end

    def dup(new_ct)
      ret = super()
      ret.init_lock
      ret.instance_variable_set('@ct', new_ct)
      ret.instance_variable_set('@lxcfs', OsCtld::Lxcfs.new(
        "ct.#{new_ct.ident}",
        uid: new_ct.root_host_uid,
        gid: new_ct.root_host_gid,
        loadavg: lxcfs.loadavg,
        cfs: lxcfs.cfs,
      ))
      ret
    end

    protected
    attr_reader :lxcfs
  end
end
