require 'fileutils'

module OsCtl::Repo
  class Local::Repository
    attr_reader :path

    def initialize(path)
      @path = File.join(path, "v#{SCHEMA}")
      @index = Local::Index.new(self)
    end

    def exist?
      index.exist?
    end

    def create
      FileUtils.mkpath(path)
      index.save
    end

    def add(vendor, variant, arch, dist, ver, opts)
      t = Base::Image.new(
        self,
        vendor,
        variant,
        arch,
        dist,
        ver,
        tags: opts[:tags],
        image: opts[:image].keys.map(&:to_s)
      )

      FileUtils.mkdir_p(t.abs_dir_path)

      opts[:image].each do |format, file|
        FileUtils.cp(file, t.abs_image_path(format))
      end

      t.tags.each do |tag|
        path = t.abs_tag_path(tag)

        if File.symlink?(path)
          next if File.readlink(path) == t.version

          File.unlink(path)

        elsif File.exist?(path)
          File.unlink(path)
        end

        File.symlink(t.version, path)
      end

      index.add(t)
      index.save
    end

    # @return [Base::Image, nil]
    def find(vendor, variant, arch, distribution, version)
      index.find(vendor, variant, arch, distribution, version)
    end

    # Remove image from the repository
    # @param image [Base::Image]
    def remove(image)
      # Remove image from the index
      index.delete(image)
      index.save

      # Remove image
      image.image.each do |v|
        path = image.abs_image_path(v)

        File.unlink(path) if File.exist?(path)
      end

      # Remove tags
      image.tags.each do |v|
        path = image.abs_tag_path(v)

        File.unlink(path) if File.symlink?(path)
      end

      # Remove empty dir from the version dir up to the repository root
      version_dir = image.abs_dir_path

      5.times.map do |i|
        File.absolute_path(File.join(version_dir, *Array.new(i, '..')))
      end.each do |dir|
        # Use Dir.empty?(dir) when we don't care for Ruby < 2.4
        break unless (Dir.entries(dir) - %w[. ..]).empty?

        Dir.rmdir(dir)
      end
    end

    def set_default_vendor(vendor)
      install_symlink('vendor', path, 'default', vendor)
      index.set_default_vendor(vendor)
      index.save
    end

    def set_default_variant(vendor, variant)
      install_symlink('variant', File.join(path, vendor), 'default', variant)
      index.set_default_variant(vendor, variant)
      index.save
    end

    def images
      index.images
    end

    protected

    attr_reader :index

    def install_symlink(type, base_path, link_name, target_name)
      path = File.join(base_path, link_name)
      target = File.join(base_path, target_name)

      if !Dir.exist?(target)
        raise GLI::BadCommandLine, "#{type} '#{target_name}' not found"

      elsif File.symlink?(path)
        return if File.readlink(path) == target_name

        File.unlink(path)

      elsif File.exist?(path)
        File.unlink(path)
      end

      File.symlink(target_name, path)
    end
  end
end
