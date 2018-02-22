module OsCtld
  class Repository::Template
    attr_reader :vendor, :variant, :arch, :distribution, :version, :tags

    def initialize(repo, attrs)
      @repo = repo
    end

    protected
    attr_reader :repo
  end
end
