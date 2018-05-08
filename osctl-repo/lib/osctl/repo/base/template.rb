module OsCtl::Repo
  class Base::Template
    def self.load(repo, data)
      new(
        repo,
        data[:vendor],
        data[:variant],
        data[:arch],
        data[:distribution],
        data[:version],
        tags: data[:tags],
        rootfs: data[:rootfs].keys.map(&:to_s)
      )
    end

    attr_reader :repo, :vendor, :variant, :arch, :distribution, :version,
      :tags, :rootfs

    def initialize(repo, vendor, variant, arch, dist, ver, opts)
      @repo = repo
      @vendor = vendor
      @variant = variant
      @arch = arch
      @distribution = dist
      @version = ver
      @tags = opts[:tags] || []
      @rootfs = opts[:rootfs]
    end

    def dump
      {
        vendor: vendor,
        variant: variant,
        arch: arch,
        distribution: distribution,
        version: version,
        tags: tags,
        rootfs: Hash[rootfs.map { |v| [v, rootfs_path(v)] } ],
      }
    end

    def dir_path
      File.join(vendor, variant, arch, distribution, version)
    end

    def abs_dir_path
      File.join(repo.path, dir_path)
    end

    def abs_tag_path(tag)
      File.join(repo.path, vendor, variant, arch, distribution, tag)
    end

    def rootfs_path(format)
      File.join(dir_path, rootfs_name(format))
    end

    def rootfs_name(format)
      case format.to_sym
      when :tar
        'rootfs.tar.gz'
      when :zfs
        'rootfs.dat.gz'
      end
    end

    def abs_rootfs_path(format)
      File.join(repo.path, rootfs_path(format))
    end

    def has_rootfs?(fmt)
      rootfs.include?(fmt)
    end

    def ==(other)
      vendor == other.vendor \
        && variant == other.variant \
        && arch == other.arch \
        && distribution == other.distribution \
        && version == other.version
    end

    def <=>(other)
      [vendor, variant, arch, distribution, version] \
      <=> \
      [other.vendor, other.variant, other.arch, other.distribution, other.version]
    end

    def to_s
      "#{distribution}-#{version}-#{arch}-#{vendor}-#{variant}"
    end

    protected
    attr_reader :repo
  end
end
