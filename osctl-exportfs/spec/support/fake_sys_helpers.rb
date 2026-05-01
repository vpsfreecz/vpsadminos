# frozen_string_literal: true

module FakeSysHelpers
  def build_fake_sys(**overrides)
    defaults = {
      bind_mount: nil,
      bind_mount_readonly: nil,
      rbind_mount: nil,
      move_mount: nil,
      make_shared: nil,
      make_rslave: nil,
      mount_proc: nil,
      mount_tmpfs: nil,
      unmount: nil,
      unmount_lazy: nil,
      unshare_ns: nil,
      setns_path: nil,
      setns_io: nil,
      chroot: nil
    }

    instance_double(OsCtl::Lib::Sys, **defaults, **overrides)
  end
end

RSpec.configure do |config|
  config.include FakeSysHelpers
end
