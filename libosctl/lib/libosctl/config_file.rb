require 'yaml'

module OsCtl::Lib
  module ConfigFile
    # Safely load YAML file
    # @param filename [String]
    def self.load_yaml_file(filename)
      File.open(filename, 'r:bom|utf-8') do |f|
        YAML.safe_load(f, filename: filename)
      end
    end

    # Safely load YAML from string
    # @param string [String]
    def self.load_yaml(string)
      YAML.safe_load(string)
    end
  end
end
