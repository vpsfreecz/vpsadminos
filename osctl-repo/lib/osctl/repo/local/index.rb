require 'json'
require 'libosctl'

module OsCtl::Repo
  class Local::Index
    include OsCtl::Lib::Utils::File

    def initialize(repo)
      @repo = repo

      if exist?
        data = JSON.parse(File.read(path), symbolize_names: true)
        @vendors = data[:vendors]
        @contents = data[:images].map { |v| Base::Image.load(repo, v) }

      else
        @vendors = {default: nil}
        @contents = []
      end
    end

    def exist?
      File.exist?(path)
    end

    def add(image)
      if i = contents.index(image)
        contents[i] = image

      else
        contents << image
      end

      if image.tags.any?
        # Remove the image's tags from previous distribution images
        contents.each do |t|
          next if t == image \
                  || t.vendor != image.vendor \
                  || t.variant != image.variant \
                  || t.arch != image.arch \
                  || t.distribution != image.distribution \

          t.tags.delete_if { |tag| image.tags.include?(tag) }
        end
      end
    end

    def find(vendor, variant, arch, distribution, version)
      contents.detect do |t|
        t.vendor == vendor \
          && t.variant == variant \
          && t.arch == arch \
          && t.distribution == distribution \
          && (t.version == version || t.tags.include?(version))
      end
    end

    def delete(image)
      contents.delete(image)
    end

    def set_default_vendor(name)
      vendors[:default] = name
    end

    def set_default_variant(vendor, name)
      vendors[vendor.to_sym] = name
    end

    def save
      regenerate_file(path, 0644) do |f|
        f.write({
          vendors: vendors,
          images: contents.sort.map(&:dump)
        }.to_json)
      end
    end

    def images
      contents.clone
    end

    protected
    attr_reader :repo, :vendors, :contents

    def path
      File.join(repo.path, 'INDEX.json')
    end
  end
end
