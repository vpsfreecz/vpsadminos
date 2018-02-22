require 'filelock'

module OsCtl::Repo
  class Remote::Repository
    attr_reader :url
    attr_accessor :path

    def initialize(url)
      @url = url
      @path = '.'
    end

    def has_index?
      File.exist?(index_path)
    end

    def lock_index
      Filelock(File.join(path, '.INDEX.json.lock')) { yield }
    end

    def index_path
      File.join(path, 'INDEX.json')
    end

    def index_url
      File.join(url, 'INDEX.json')
    end
  end
end
