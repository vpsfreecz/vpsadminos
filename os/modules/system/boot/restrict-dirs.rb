#!@ruby@/bin/ruby
require 'json'

DATA = '@data@'

class RestrictDirs
  class Entry
    attr_reader :path, :subdirs

    def initialize(parent, path, opts)
      @parent = parent
      @path = path
      @allow =
        if opts === true || opts === false
          opts
        elsif opts.has_key?('allow')
          opts['allow'] ? true : false
        else
          true
        end

      if !opts.is_a?(Hash) || !opts['subdirs']
        @subdirs = {}
      else
        @subdirs = Hash[opts['subdirs'].map do |subdir, subopts|
          subpath = File.join(path, subdir)
          [subpath, self.class.new(self, subpath, subopts)]
        end]
      end
    end

    def has_subdirs?
      @subdirs.any?
    end

    def has_subdir?(path)
      @subdirs.has_key?(path)
    end

    def allow?
      @allow
    end
  end

  def initialize(json_file)
    @dirs = JSON.parse(File.read(json_file)).map do |k, v|
      Entry.new(nil, k, v)
    end
  end

  def run
    @dirs.each { |entry| restrict(entry) }
  end

  protected
  def restrict(entry)
    unless entry.has_subdirs?
      chmod(entry.path) unless entry.allow?
      return
    end

    Dir.entries(entry.path).each do |f|
      next if %w(. ..).include?(f)

      path = File.join(entry.path, f)

      if entry.has_subdir?(path)
        restrict(entry.subdirs[path])
      else
        chmod(path)
      end
    end
  end

  def chmod(path)
    st = File.stat(path)
    File.chmod(st.mode & 0770, path)
  end
end

rd = RestrictDirs.new('@data@')
rd.run
