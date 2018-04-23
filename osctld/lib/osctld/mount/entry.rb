module OsCtld
  class Mount::Entry
    PARAMS = %i(fs mountpoint type opts automount dataset)
    attr_reader :mountpoint, :type, :opts, :automount, :dataset

    # Load from config
    def self.load(ct, cfg)
      new(
        cfg['fs'],
        cfg['mountpoint'],
        cfg['type'],
        cfg['opts'],
        cfg['automount'],
        cfg['dataset'] && OsCtl::Lib::Zfs::Dataset.new(
          File.join(ct.dataset.name, cfg['dataset']),
          base: ct.dataset.name
        )
      )
    end

    def initialize(fs, mountpoint, type, opts, automount, dataset = nil)
      @fs = fs
      @mountpoint = mountpoint
      @type = type
      @opts = opts
      @automount = automount
      @dataset = dataset
    end

    def fs
      dataset ? dataset.private_path : @fs
    end

    def lxc_mountpoint
      ret = String.new(mountpoint)
      ret.slice!(0) while ret.start_with?('/')
      ret
    end

    # Export to client
    def export
      {
        fs: fs,
        mountpoint: mountpoint,
        type: type,
        opts: opts,
        automount: automount,
        dataset: dataset && dataset.relative_name,
      }
    end

    # Dump to config
    def dump
      {
        'fs' => dataset ? nil : fs,
        'mountpoint' => mountpoint,
        'type' => type,
        'opts' => opts,
        'automount' => automount,
        'dataset' => dataset && dataset.relative_name,
      }
    end

    alias_method :automount?, :automount
  end
end
