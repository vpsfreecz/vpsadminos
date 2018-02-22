require 'json'

module OsCtl::Repo
  class Remote::Index
    def self.from_string(repo, str)
      new(repo, JSON.parse(str, symbolize_names: true))
    end

    def self.from_file(repo, path)
      from_string(repo, File.read(path))
    end

    attr_reader :repo

    def initialize(repo, data)
      @repo = repo
      @vendors = data[:vendors]
      @contents = data[:templates].map { |v| Remote::Template.load(repo, v) }
    end

    def lookup(vendor, variant, arch, dist, vtag)
      real_vendor = vendor == 'default' ? vendors[:default] : vendor
      real_variant = variant == 'default' ? vendors[real_vendor.to_sym] : variant

      contents.detect do |t|
        t.vendor == real_vendor \
          && t.variant == real_variant \
          && t.arch == arch \
          && t.distribution == dist \
          && (t.version == vtag || t.tags.include?(vtag))
      end
    end

    def templates
      @contents
    end

    protected
    attr_reader :vendors, :contents
  end
end
