require 'etc'
require 'osctl/repo/locator'
require 'osctl/repo/constants'

module OsCtld
  module Utils::Repository
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
          'get',
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

      else
        fail "osctl-repo get failed with exit status #{$?.exitstatus}"
      end
    end
  end
end
