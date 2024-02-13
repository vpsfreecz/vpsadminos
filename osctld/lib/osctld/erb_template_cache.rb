require 'erb'
require 'singleton'

module OsCtld
  class ErbTemplateCache
    class << self
      def [](name)
        instance[name]
      end
    end

    include Singleton

    def initialize
      @templates = {}
      load
    end

    def load
      templates.clear

      Dir.glob('**/*.erb', base: OsCtld.template_dir).each do |tpl|
        content = File.read(File.join(OsCtld.template_dir, tpl))
        templates[tpl[0..-5]] = ERB.new(content, trim_mode: '-')
      end
    end

    # @param name [String]
    # @return [ERB]
    def [](name)
      templates[name].clone
    end

    protected

    attr_reader :templates
  end
end
