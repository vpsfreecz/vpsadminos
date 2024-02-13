require 'filelock'
require 'osctl/repo/base/image'

module OsCtl::Repo
  class Remote::Image < Base::Image
    def abs_image_url(format)
      File.join(repo.url, image_path(format))
    end

    def abs_cache_path(format)
      abs_image_path(format)
    end

    def cached?(format)
      File.exist?(abs_cache_path(format))
    end

    def lock(format, &)
      Filelock(
        File.join(abs_dir_path, ".#{image_name(format)}.lock"),
        timeout: 60 * 60, &
      )
    end

    def dump
      ret = super
      ret[:cached] = ret[:image].select do |format, _path|
        cached?(format)
      end.map { |format, _path| format }
      ret
    end
  end
end
