require 'libosctl'
require 'yaml'
require 'osctld/lockable'

module OsCtld
  class Container::RunConfiguration
    include Lockable
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::File

    # @param ct [Container]
    def self.load(ct)
      ctrc = new(ct, load_conf: false)

      if ctrc.exist?
        ctrc.load_conf
        ctrc
      else
        nil
      end
    end

    # @return [Container]
    attr_reader :ct

    attr_inclusive_reader :dataset, :distribution, :version, :arch

    # @param ct [Container]
    def initialize(ct, load_conf: true)
      init_lock
      @ct = ct
      self.load_conf(from_file: load_conf)
    end

    def assets(add)
      add.file(
        file_path,
        desc: 'Container runtime configuration',
        user: 0,
        group: 0,
        mode: 0400,
        optional: true,
      )
    end

    %i(
      id ident pool user group uid_map gid_map lxc_dir log_path config_path
      log_type
    ).each do |v|
      define_method(v) do |*args, **kwargs|
        ct.send(v, *args, **kwargs)
      end
    end

    # Countainer dataset mountpoint
    # @return [String]
    def dir
      dataset.mountpoint
    end

    # Container rootfs path
    # @return [String]
    def rootfs
      File.join(dir, 'private')

    rescue SystemCommandFailed
      # Dataset for staged containers does not have to exist yet, relevant
      # primarily for ct show/list
      nil
    end

    # Mount the container's dataset
    # @param force [Boolean] ensure the datasets are mounted even if osctld
    #                        already mounted them
    def mount(force: false)
      return if !force && mounted
      dataset.mount(recursive: true)
      self.mounted = true
    end

    # Check if the container's dataset is mounted
    # @param force [Boolean] check if the dataset is mounted even if osctld
    #                        already mounted it
    def mounted?(force: false)
      if force || mounted.nil?
        self.mounted = dataset.mounted?(recursive: true)
      else
        mounted
      end
    end

    def exist?
      File.exist?(file_path)
    end

    def dump
      {
        'dataset' => dataset.to_s,
        'distribution' => distribution,
        'version' => version,
        'arch' => arch,
      }
    end

    def load_conf(from_file: true)
      cfg =
        if from_file && File.exist?(file_path)
          YAML.load_file(file_path)
        else
          {}
        end

      @dataset =
        if cfg['dataset']
          OsCtl::Lib::Zfs::Dataset.new(cfg['dataset'], base: cfg['dataset'])
        else
          ct.dataset
        end
      @distribution = cfg['distribution'] || ct.distribution
      @version = cfg['version'] || ct.version
      @arch = cfg['arch'] || ct.arch
      nil
    end

    def save
      begin
        Dir.mkdir(dir_path)
      rescue Errno::EEXIST
      end

      regenerate_file(file_path, 0400) do |new|
        new.write(YAML.dump(dump))
      end
    end

    def destroy
      File.unlink(file_path)
    rescue Errno::ENOENT
    end

    protected
    attr_synchronized_accessor :mounted

    def dir_path
      File.join(ct.pool.ct_dir, ct.id)
    end

    def file_path
      File.join(dir_path, 'config.yml')
    end
  end
end
