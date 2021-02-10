module OsCtld
  class Mount::Entry
    PARAMS = %i(fs mountpoint type opts automount dataset temp)
    attr_reader :mountpoint, :type, :opts, :automount, :dataset, :temp, :in_config

    # Load from config
    def self.load(ct, cfg)
      new(
        cfg['fs'],
        cfg['mountpoint'],
        cfg['type'],
        cfg['opts'],
        cfg['automount'],
        dataset: cfg['dataset'] && OsCtl::Lib::Zfs::Dataset.new(
          File.join(ct.dataset.name, cfg['dataset']),
          base: ct.dataset.name
        ),
        temp: cfg['temporary'],
      )
    end

    def initialize(fs, mountpoint, type, opts, automount, dataset: nil, temp: false, in_config: false)
      @fs = fs
      @mountpoint = mountpoint
      @type = type
      @opts = opts
      @automount = automount
      @dataset = dataset
      @temp = temp
      @in_config = in_config
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
        temporary: temp,
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
        'temporary' => temp,
      }
    end

    alias_method :automount?, :automount
    alias_method :temp?, :temp
    alias_method :in_config?, :in_config
  end
end
