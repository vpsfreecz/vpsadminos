require 'filelock'
require 'osctl/repo/base/template'

module OsCtl::Repo
  class Remote::Template < Base::Template
    def abs_image_url(format)
      File.join(repo.url, image_path(format))
    end

    def abs_cache_path(format)
      abs_image_path(format)
    end

    def cached?(format)
      File.exist?(abs_cache_path(format))
    end

    def lock(format)
      Filelock(
        File.join(abs_dir_path, ".#{image_name(format)}.lock"),
        timeout: 60*60
      ) { yield }
    end

    def dump
      ret = super
      ret[:cached] = ret[:image].select do |format, path|
        cached?(format)
      end.map { |format, path| format }
      ret
    end
  end
end
