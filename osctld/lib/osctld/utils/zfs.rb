module OsCtld::Utils
  module Zfs
    def zfs(cmd, opts, component, cmd_opts = {})
      syscmd("zfs #{cmd} #{opts} #{component}", cmd_opts)
    end

    def user_ds(name)
      "#{OsCtld::USER_DS}/#{name}"
    end

    def user_ct_ds(name)
      "#{user_ds(name)}/ct"
    end

    def user_dir(name)
      "/#{user_ds(name)}"
    end

    def ct_ds(user, id)
      "#{user_ct_ds(user)}/#{id}"
    end

    def ct_dir(user, id)
      "/#{ct_ds(user, id)}"
    end
  end
end
