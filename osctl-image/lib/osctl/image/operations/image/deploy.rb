require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Image::Deploy < Operations::Base
    # @return [Operations::Image::Build]
    attr_reader :build

    # @return [String]
    attr_reader :repo_dir

    # @return [Array<String>]
    attr_reader :tags

    # @param build [Operations::Image::Build]
    # @param repo_dir [String]
    # @param tags [Array<String>]
    def initialize(build, repo_dir, tags: [])
      super()
      @build = build
      @repo_dir = repo_dir
      @tags = tags
    end

    def execute
      Operations::Repository::Create.run(repo_dir)

      Operations::Repository::AddImage.run(
        repo_dir,
        {
          tar: build.output_tar,
          zfs: build.output_stream
        }.compact,
        build.image_attrs,
        tags
      )
    end
  end
end
