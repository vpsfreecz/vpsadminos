require 'json'

module OsCtld
  # One-time config for osctld
  class RunState::StartConfig
    # @return [String]
    attr_reader :path

    # @param path [String]
    def initialize(path)
      @path = path
      open_config
    end

    def exist?
      @exist
    end

    def close
      File.unlink(path) if exist?
    rescue Errno::ENOENT
    end

    protected

    attr_reader :cfg

    def open_config
      @cfg = {}

      begin
        data = File.read(path)
      rescue Errno::ENOENT
        @exist = false
        return
      end

      @exist = true
      @cfg = JSON.parse(data)
    end
  end
end
