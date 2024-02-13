require 'filelock'

module OsCtl::Repo
  class Remote::Repository
    attr_reader :url, :path

    def initialize(url)
      @url = File.join(url, "v#{SCHEMA}")
      @path = File.join('.', "v#{SCHEMA}")
    end

    def path=(v)
      @path = File.join(v, "v#{SCHEMA}")
    end

    def has_index?
      File.exist?(index_path)
    end

    def lock_index(&)
      Filelock(File.join(path, '.INDEX.json.lock'), &)
    end

    def index_path
      File.join(path, 'INDEX.json')
    end

    def index_url
      File.join(url, 'INDEX.json')
    end
  end
end
