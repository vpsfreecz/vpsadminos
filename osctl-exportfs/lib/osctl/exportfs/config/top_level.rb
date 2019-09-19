require 'libosctl'
require 'yaml'

module OsCtl::ExportFS
  class Config::TopLevel
    include OsCtl::Lib::Utils::File

    # @return [String]
    attr_reader :path

    # @return [Config::Exports]
    attr_reader :exports

    # @param path [String]
    def initialize(path)
      @path = path

      if File.exist?(path)
        read_config
      else
        @exports = Config::Exports.new([])
      end
    end

    def save
      regenerate_file(path, 0644) do |new|
        new.write(YAML.dump(dump))
      end
    end

    protected
    def read_config
      data = YAML.load_file(path)
      @exports = Config::Exports.new(data['exports'] || [])
    end

    def dump
      {
        'exports' => exports.dump,
      }
    end
  end
end
