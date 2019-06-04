require 'etc'
require 'json'
require 'osctl/repo/locator'
require 'osctl/repo/constants'

module OsCtld
  class OsCtlRepo
    attr_reader :repo

    # @param repo [Repository]
    def initialize(repo)
      @repo = repo
    end

    # @return [Array<Repository::Image>]
    def list_images
      exit_status, data = osctl_repo(
        File.join(OsCtl::Repo.root, 'bin', 'osctl-repo'),
        'remote', 'ls',
        '--cache', repo.cache_path,
        repo.url,
      )

      case exit_status
      when OsCtl::Repo::EXIT_OK
        JSON.parse(data, symbolize_names: true).map { |v| Repository::Image.new(v) }

      when OsCtl::Repo::EXIT_HTTP_ERROR, OsCtl::Repo::EXIT_NETWORK_ERROR
        raise ImageRepositoryUnavailable

      else
        fail "osctl-repo remote ls failed with exit status #{exit_status}"
      end
    end

    # @param tpl [Hash]
    # @option tpl [String] :distribution
    # @option tpl [String] :version
    # @option tpl [String] :arch
    # @option tpl [String] :vendor
    # @option tpl [String] :variant
    # @param format [:tar, :zfs]
    # @return [String, nil] path to the image in cache
    def get_image_path(tpl, format)
      exit_status, data = osctl_repo(
        File.join(OsCtl::Repo.root, 'bin', 'osctl-repo'),
        'remote', 'get', 'path',
        '--cache', repo.cache_path,
        repo.url,
        tpl[:vendor], tpl[:variant], tpl[:arch], tpl[:distribution], tpl[:version],
        format.to_s,
      )

      case exit_status
      when OsCtl::Repo::EXIT_OK
        data.strip

      when OsCtl::Repo::EXIT_FORMAT_NOT_FOUND
        nil

      when OsCtl::Repo::EXIT_IMAGE_NOT_FOUND
        raise ImageNotFound

      when OsCtl::Repo::EXIT_HTTP_ERROR, OsCtl::Repo::EXIT_NETWORK_ERROR
        raise ImageRepositoryUnavailable

      else
        fail "osctl-repo remote get path failed with exit status #{exit_status}"
      end
    end

    protected
    # @return [Array<Integer, String>] exit status and data
    def osctl_repo(*args)
      r, w = IO.pipe

      pid = Process.fork do
        SwitchUser.switch_to_system(
          Repository::USER,
          Repository::UID,
          Etc.getgrnam('nogroup').gid,
          RunState::REPOSITORY_DIR,
        )

        ENV['GLI_DEBUG'] = 'true'

        STDOUT.reopen(w)
        r.close

        Process.exec(*args)
      end

      w.close

      data = r.read
      r.close
      Process.wait(pid)
      [$?.exitstatus, data]
    end
  end
end
