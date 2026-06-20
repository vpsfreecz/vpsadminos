require 'fileutils'
require 'forwardable'
require 'libosctl'
require 'shellwords'
require 'singleton'

module OsCtld
  class BpfFs
    include Singleton
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    FS = '/run/osctl/bpf'.freeze

    CT_FS = '/run/osctl/ct-bpf'.freeze

    ROOT_DIR = File.join(FS, 'osctl')

    PROG_DIR = File.join(ROOT_DIR, 'progs')

    POOL_DIR = File.join(ROOT_DIR, 'pools')

    class << self
      extend Forwardable

      def_delegators :instance, :setup, :add_pool, :remove_pool, :prog_pin_path,
                     :prog_pinned?, :list_progs, :link_pin_path, :link_pinned?, :list_links,
                     :ct_mount_path, :setup_ct, :remove_ct
    end

    def setup
      FileUtils.mkdir_p(PROG_DIR)
      FileUtils.mkdir_p(CT_FS)
    end

    def add_pool(pool_name)
      FileUtils.mkdir_p(File.join(pool_dir(pool_name), 'links'))
      FileUtils.mkdir_p(ct_pool_dir(pool_name))
    end

    def remove_pool(pool_name)
      if Dir.exist?(ct_pool_dir(pool_name))
        Dir.each_child(ct_pool_dir(pool_name)) do |ct_id|
          remove_ct(pool_name, ct_id)
        end
      end

      FileUtils.rm_rf(ct_pool_dir(pool_name), secure: true)
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

    def ct_mount_path(pool_name, ct_id)
      File.join(ct_pool_dir(pool_name), ct_id)
    end

    def setup_ct(pool_name, ct_id, root_uid:, root_gid:)
      path = ct_mount_path(pool_name, ct_id)
      opts = ct_mount_options(root_uid, root_gid)

      FileUtils.mkdir_p(path)

      mounted_type = mount_type(path)

      if mounted_type == 'bpf'
        syscmd("mount -o remount,#{Shellwords.escape(opts)} #{Shellwords.escape(path)}")
      else
        syscmd("umount -f #{Shellwords.escape(path)}", valid_rcs: [32]) if mounted_type
        syscmd("mount -t bpf -o #{Shellwords.escape(opts)} bpf #{Shellwords.escape(path)}")
      end

      syscmd("mount --make-rprivate #{Shellwords.escape(path)}")
      path
    end

    def remove_ct(pool_name, ct_id)
      path = ct_mount_path(pool_name, ct_id)

      syscmd("umount -f #{Shellwords.escape(path)}", valid_rcs: [32]) if Dir.exist?(path)
      FileUtils.rm_rf(path, secure: true)
    end

    def log_type
      'bpf-fs'
    end

    protected

    def pool_dir(pool_name)
      File.join(POOL_DIR, pool_name)
    end

    def ct_pool_dir(pool_name)
      File.join(CT_FS, pool_name)
    end

    def ct_mount_options(root_uid, root_gid)
      [
        'nosuid',
        'nodev',
        'noexec',
        "uid=#{Integer(root_uid)}",
        "gid=#{Integer(root_gid)}",
        'mode=700'
      ].join(',')
    end

    def mount_type(path)
      File.readlines('/proc/self/mountinfo').any? do |line|
        parts = line.split
        next unless parts.fetch(4) == path

        sep = parts.index('-')
        return parts.fetch(sep + 1) if sep
      end

      nil
    end
  end
end
