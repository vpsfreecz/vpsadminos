#!@ruby@/bin/ruby
require 'json'

DATA = '@data@'

class RestrictDirs
  class Entry
    attr_reader :path, :subdirs

    def initialize(parent, path, opts)
      @parent = parent
      @path = path
      @default =
        if opts === true || opts === false
          opts
        elsif opts.has_key?('default')
          opts['default'] ? true : false
        else
          false
        end
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

    def find_subdir(path)
      @subdirs.each do |path_pattern, dir|
        return dir if File.fnmatch?(path_pattern, path)
      end

      nil
    end

    def allow?
      @allow
    end

    def allow_unlisted_subdir?
      @default
    end
  end

  def initialize(json_file)
    @dirs = JSON.parse(File.read(json_file)).map do |k, v|
      Entry.new(nil, k, v)
    end
  end

  def run
    @dirs.each { |entry| restrict(entry, entry.path) }
  end

  protected
  def restrict(entry, realpath)
    unless entry.has_subdirs?
      chmod(realpath) unless entry.allow?
      return
    end

    Dir.entries(realpath).each do |f|
      next if %w(. ..).include?(f)

      path = File.join(realpath, f)
      subdir = entry.find_subdir(path)

      if subdir
        restrict(subdir, path)
      elsif !entry.allow_unlisted_subdir?
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
