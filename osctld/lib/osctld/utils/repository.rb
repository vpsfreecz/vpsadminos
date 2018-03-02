require 'etc'
require 'json'
require 'osctl/repo/locator'
require 'osctl/repo/constants'

module OsCtld
  module Utils::Repository
    def osctl_repo_ls(repo)
      r, w = IO.pipe

      pid = Process.fork do
        SwitchUser.switch_to_system(
          Repository::USER,
          Repository::UID,
          Etc.getgrnam('nogroup').gid,
          RunState::REPOSITORY_DIR
        )

        STDOUT.reopen(w)
        r.close

        Process.exec(
          #File.join(OsCtl::Repo.root, 'bin', 'osctl-repo-dev'),
          File.join(OsCtl::Repo.root, 'bin', 'osctl-repo'),
          'remote', 'ls',
          '--cache', repo.cache_path,
          repo.url
        )
      end

      w.close

      data = r.read
      r.close
      Process.wait(pid)

      case $?.exitstatus
      when OsCtl::Repo::EXIT_OK
        JSON.parse(data, symbolize_names: true).map { |v| Repository::Template.new(v) }

      when OsCtl::Repo::EXIT_HTTP_ERROR, OsCtl::Repo::EXIT_NETWORK_ERROR
        raise TemplateRepositoryUnavailable

      else
        fail "osctl-repo remote ls failed with exit status #{$?.exitstatus}"
      end
    end

    def osctl_repo_get(repo, tpl, format, io)
      pid = Process.fork do
        SwitchUser.switch_to_system(
          Repository::USER,
          Repository::UID,
          Etc.getgrnam('nogroup').gid,
          RunState::REPOSITORY_DIR
        )

        STDOUT.reopen(io)

        Process.exec(
          #File.join(OsCtl::Repo.root, 'bin', 'osctl-repo-dev'),
          File.join(OsCtl::Repo.root, 'bin', 'osctl-repo'),
          'remote', 'get',
          '--cache', repo.cache_path,
          repo.url,
          tpl[:vendor], tpl[:variant], tpl[:arch], tpl[:distribution], tpl[:version],
          format
        )
      end

      io.close
      Process.wait(pid)

      case $?.exitstatus
      when OsCtl::Repo::EXIT_OK
        true

      when OsCtl::Repo::EXIT_FORMAT_NOT_FOUND
        false

      when OsCtl::Repo::EXIT_TEMPLATE_NOT_FOUND
        raise TemplateNotFound

      when OsCtl::Repo::EXIT_HTTP_ERROR, OsCtl::Repo::EXIT_NETWORK_ERROR
        raise TemplateRepositoryUnavailable

      else
        fail "osctl-repo remote get failed with exit status #{$?.exitstatus}"
      end
    end
  end
end
