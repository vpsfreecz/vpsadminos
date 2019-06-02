require 'fileutils'
require 'osctl/repo'
require 'osctl/template/operations/base'

module OsCtl::Template
  class Operations::Repository::Create < Operations::Base
    # @return [String]
    attr_reader :repo_dir

    # @param repo_dir [String]
    def initialize(repo_dir)
      @repo_dir = repo_dir
    end

    def execute
      repo = OsCtl::Repo::Local::Repository.new(repo_dir)

      unless repo.exist?
        FileUtils.mkpath(repo_dir)
        repo.create
      end

      true
    end
  end
end
