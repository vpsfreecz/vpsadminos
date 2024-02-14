require 'osctl/repo'
require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Repository::GetImagePath < Operations::Base
    # @return [String]
    attr_reader :repo_dir

    # @return [Hash]
    attr_reader :attrs

    # @return [String]
    attr_reader :format

    # @param repo_dir [String]
    # @param attrs [Hash]
    # @option attrs [String] :distribution
    # @option attrs [String] :version
    # @option attrs [String] :arch
    # @option attrs [String] :vendor
    # @option attrs [String] :variant
    # @param format [:tar, :zfs]
    def initialize(repo_dir, attrs, format)
      super()
      @repo_dir = repo_dir
      @attrs = attrs
      @format = format.to_s
    end

    # @return [String] path to the image
    def execute
      repo = OsCtl::Repo::Local::Repository.new(repo_dir)

      unless repo.exist?
        raise OperationError, 'repository does not exist'
      end

      img = repo.find(
        attrs[:vendor],
        attrs[:variant],
        attrs[:arch],
        attrs[:distribution],
        attrs[:version]
      )

      raise OperationError, 'image not found' unless img
      raise OperationError 'image format not found' unless img.has_image?(format)

      File.join(repo_dir, img.version_image_path(format))
    end
  end
end
