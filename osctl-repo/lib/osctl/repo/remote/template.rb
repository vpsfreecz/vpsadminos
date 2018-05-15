require 'filelock'
require 'osctl/repo/base/template'

module OsCtl::Repo
  class Remote::Template < Base::Template
    def abs_rootfs_url(format)
      File.join(repo.url, rootfs_path(format))
    end

    def cached?(format)
      File.exist?(abs_rootfs_path(format))
    end

    def lock(format)
      Filelock(
        File.join(abs_dir_path, ".#{rootfs_name(format)}.lock"),
        timeout: 60*60
      ) { yield }
    end

    def dump
      ret = super
      ret[:cached] = ret[:rootfs].select do |format, path|
        cached?(format)
      end.map { |format, path| format }
      ret
    end
  end
end
