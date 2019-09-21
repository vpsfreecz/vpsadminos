require 'erb'
require 'fileutils'

module OsCtl::ExportFS
  class ErbTemplate
    def self.render(name, vars)
      t = new(name, vars)
      t.render
    end

    def self.render_to(name, vars, path)
      File.write("#{path}.new", render(name, vars))
      File.rename("#{path}.new", path)
    end

    def self.render_to_if_changed(name, vars, path)
      tmp_path = "#{path}.new"
      File.write(tmp_path, render(name, vars))

      if !File.exist?(path) || !FileUtils.identical?(path, tmp_path)
        File.rename(tmp_path, path)

      else
        File.unlink(tmp_path)
      end
    end

    def initialize(name, vars)
      path = File.join(OsCtl::ExportFS.root, 'templates', "#{name}.erb")
      @_tpl = ERB.new(File.new(path).read, 0, '-')

      vars.each do |k, v|
        if v.is_a?(Proc)
          define_singleton_method(k, &v)
        elsif v.is_a?(Method)
          define_singleton_method(k) { |*args| v.call(*args) }
        else
          define_singleton_method(k) { v }
        end
      end
    end

    def render
      @_tpl.result(binding)
    end
  end
end
