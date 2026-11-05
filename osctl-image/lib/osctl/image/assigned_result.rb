require 'digest'
require 'rubygems/package'
require 'yaml'

module OsCtl::Image
  module AssignedResult
    def self.verify(path, format, tuple)
      config = nil
      File.open(path, 'rb') do |file|
        Gem::Package::TarReader.new(file) do |tar|
          tar.each do |entry|
            next unless entry.full_name == 'config/container.yml'

            config = YAML.safe_load(entry.read)
            break
          end
        end
      end
      unless config && tuple.all? { |key, value| config[key] == value }
        raise OperationError, "export tuple differs from assignment: #{path}"
      end

      { 'format' => format, 'path' => File.absolute_path(path),
        'size' => File.size(path), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end
  end
end
