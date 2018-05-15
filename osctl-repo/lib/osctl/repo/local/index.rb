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
        @contents = data[:templates].map { |v| Base::Template.load(repo, v) }

      else
        @vendors = {default: nil}
        @contents = []
      end
    end

    def exist?
      File.exist?(path)
    end

    def add(template)
      if i = contents.index(template)
        contents[i] = template

      else
        contents << template
      end

      if template.tags.any?
        # Remove the template's tags from previous distribution templates
        contents.each do |t|
          next if t == template \
                  || t.vendor != template.vendor \
                  || t.variant != template.variant \
                  || t.arch != template.arch \
                  || t.distribution != template.distribution \

          t.tags.delete_if { |tag| template.tags.include?(tag) }
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

    def delete(template)
      contents.delete(template)
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
          templates: contents.sort.map(&:dump)
        }.to_json)
      end
    end

    def templates
      contents.clone
    end

    protected
    attr_reader :repo, :vendors, :contents

    def path
      File.join(repo.path, 'INDEX.json')
    end
  end
end
