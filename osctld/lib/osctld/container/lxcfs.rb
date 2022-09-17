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

    # @return [Container]
    attr_reader :ct

    # @return [Boolean]
    attr_reader :enable

    def_delegators :lxcfs, :loadavg, :cfs, :mountpoint

    # @param ct [Container]
    def initialize(ct, enable: true, loadavg: true, cfs: true)
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

    def ensure_and_wait
      return unless enable

      lxcfs.ensure_start
      lxcfs.wait(timeout: 20)
    end

    def ensure_stop
      lxcfs.ensure_stop
    end

    def running?
      lxcfs.running?
    end

    def configure(loadavg: true, cfs: true)
      @enable = true
      lxcfs.configure(loadavg: loadavg, cfs: cfs)
      lxcfs.restart if !ct.running? && lxcfs.running?
    end

    def chown(user)
      if ct.user != user
        fail 'programming error: expected container user to be changed'
      end

      lxcfs.chown(ct.root_host_uid, ct.root_host_gid)
    end

    def disable
      @enable = false
      destroy unless ct.running?
    end

    def destroy
      lxcfs.ensure_destroy
    end

    def post_mount_params
      {
        mountpoint: lxcfs.mountpoint,
        mount_files: lxcfs.mount_files,
      }
    end

    def dump
      {
        'enable' => enable,
        'loadavg' => lxcfs.loadavg,
        'cfs' => lxcfs.cfs,
      }
    end

    def dup(new_ct)
      ret = super()
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
