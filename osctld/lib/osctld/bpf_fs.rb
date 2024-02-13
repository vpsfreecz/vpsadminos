require 'fileutils'
require 'forwardable'
require 'singleton'

module OsCtld
  class BpfFs
    include Singleton

    FS = '/sys/fs/bpf'

    ROOT_DIR = File.join(FS, 'osctl')

    PROG_DIR = File.join(ROOT_DIR, 'progs')

    POOL_DIR = File.join(ROOT_DIR, 'pools')

    class << self
      extend Forwardable

      def_delegators :instance, :setup, :add_pool, :remove_pool, :prog_pin_path,
                     :prog_pinned?, :list_progs, :link_pin_path, :link_pinned?, :list_links
    end

    def setup
      FileUtils.mkdir_p(PROG_DIR)
    end

    def add_pool(pool_name)
      FileUtils.mkdir_p(File.join(pool_dir(pool_name), 'links'))
    end

    def remove_pool(pool_name)
      FileUtils.rm_rf(pool_dir(pool_name), secure: true)
    end

    def prog_pin_path(prog_name)
      File.join(PROG_DIR, prog_name)
    end

    def prog_pinned?(prog_name)
      File.exist?(prog_pin_path(prog_name))
    end

    def list_progs
      dir = PROG_DIR

      Dir.entries(dir).select do |f|
        !%w[. ..].include?(f) && File.file?(File.join(dir, f))
      end
    rescue Errno::ENOENT
      []
    end

    def link_pin_path(pool_name, link_name)
      File.join(pool_dir(pool_name), 'links', link_name)
    end

    def link_pinned?(pool_name, link_name)
      File.exist?(link_pin_path(pool_name, link_name))
    end

    def list_links(pool_name)
      dir = File.join(pool_dir(pool_name), 'links')

      Dir.entries(dir).select do |f|
        !%w[. ..].include?(f) && File.file?(File.join(dir, f))
      end
    rescue Errno::ENOENT
      []
    end

    protected

    def pool_dir(pool_name)
      File.join(POOL_DIR, pool_name)
    end
  end
end
