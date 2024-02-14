require 'osctl/repo'
require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Repository::AddImage < Operations::Base
    # @return [String]
    attr_reader :repo_dir

    # @return [Hash<Symbol, String>]
    attr_reader :images

    # @return [Hash]
    attr_reader :attrs

    # @return [Array<String>]
    attr_reader :tags

    # @param repo_dir [String]
    # @param images [String]
    # @param attrs [Hash]
    # @option attrs [String] :distribution
    # @option attrs [String] :version
    # @option attrs [String] :arch
    # @option attrs [String] :vendor
    # @option attrs [String] :variant
    # @param tags [Array<String>]
    def initialize(repo_dir, images, attrs, tags)
      super()
      @repo_dir = repo_dir
      @images = images
      @attrs = attrs
      @tags = tags
    end

    def execute
      repo = OsCtl::Repo::Local::Repository.new(repo_dir)

      unless repo.exist?
        raise OperationError, 'repository does not exist'
      end

      repo.add(
        attrs[:vendor],
        attrs[:variant],
        attrs[:arch],
        attrs[:distribution],
        attrs[:version],
        tags:,
        image: images
      )
    end
  end
end
