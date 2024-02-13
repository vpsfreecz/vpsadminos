require 'osctld/devices/v1/group_configurator'

module OsCtld
  class Devices::V1::ContainerConfigurator < Devices::V1::GroupConfigurator
    def init(devices)
      log(:info, owner, "Configuring cgroup #{owner.cgroup_path} for devices")
      create(devices)
    end

    def reconfigure(devices)
      clear

      abs_all_cgroup_paths.each do |cgpath, req|
        next unless prepare_cgroup(cgpath, req)

        devices.each { |dev| do_allow_device(dev, cgpath) }
      end
    end

    def add_device(device)
      abs_all_cgroup_paths.each do |cgpath, req|
        next unless prepare_cgroup(cgpath, req)

        do_allow_device(device, cgpath)
      end
    end

    def remove_device(device)
      abs_all_cgroup_paths.reverse_each do |cgpath, req|
        next unless prepare_cgroup(cgpath, req)

        do_deny_device(device, cgpath)
      end
    end

    def apply_changes(changes)
      abs_all_cgroup_paths.each do |cgpath, req|
        next unless prepare_cgroup(cgpath, req)

        do_apply_changes(changes, cgpath)
      end
    end

    protected

    alias ct owner

    def create(devices)
      rel_group_cgroup_paths.zip(abs_group_cgroup_paths).each do |rel, abs|
        next if !rel[1] || !abs[1]

        rel_path = rel[0]
        abs_path = abs[0]

        if CGroup.mkpath('devices', rel_path.split('/'))
          do_deny_all(abs_path)
          do_configure(ct.group.devices, abs_path)
        end
      end

      rel_ct_cgroup_paths.zip(abs_ct_cgroup_paths).each do |rel, abs|
        next if !rel[1] || !abs[1]

        rel_path = rel[0]
        abs_path = abs[0]

        if CGroup.mkpath('devices', rel_path.split('/'))
          do_deny_all(abs_path)
          do_configure(devices, abs_path)
        end
      end

      abs_ct_chowned_cgroup_paths.each do |abs, req, uid, gid|
        next unless prepare_cgroup(abs, req)

        File.chown(uid || ct.user.ugid, gid || ct.user.ugid, abs)
      end
    end

    # Returns a list of relative paths of the container's group cgroups.
    #
    # These cgroups share the settings of the container's group.
    #
    # @return [Array]
    def rel_group_cgroup_paths
      [
        # <group>/<user>
        [ct.group.full_cgroup_path(ct.user), true]
      ]
    end

    # Returns a list of all relative cgroup paths that need to be configured for
    # this container, from the top down.
    #
    # The returned array contains pairs: `[String, Boolean]`. The `String`
    # is the path itself, while the `Boolean` determines whether this path
    # should be created. Paths that do not need to be created are configured
    # only if they already exist. This is used only for the `./lxc.payload.<ct>`
    # cgroup, which LXC wants to create by itself.
    #
    # @return [Array]
    def rel_ct_cgroup_paths
      [
        # <group>/<user>/<ct>
        [ct.base_cgroup_path, true],

        # <group>/<user>/<ct>/user-owned
        [ct.cgroup_path, true],

        # <group>/<user>/<ct>/user-owned/lxc.payload.<ct>
        [File.join(ct.cgroup_path, "lxc.payload.#{ct.id}"), false]
      ]
    end

    # Returns a list of absolute paths of the container's group cgroups
    # @return [Array]
    def abs_group_cgroup_paths
      to_abs_paths(rel_group_cgroup_paths)
    end

    # Returns a list of all absolute cgroup paths that need to be configured for
    # this container, from the top down.
    # @return [Array]
    def abs_ct_cgroup_paths
      to_abs_paths(rel_ct_cgroup_paths)
    end

    # Returns a list of the container's absolute cgroup paths that are to be
    # chowned to the user.
    # @return [Array]
    def abs_ct_chowned_cgroup_paths
      to_abs_paths([
                     # <group>/<user>/<ct>/user-owned
                     [ct.cgroup_path, true],

                     # <group>/<user>/<ct>/user-owned/lxc.payload.<ct>
                     [File.join(ct.cgroup_path, "lxc.payload.#{ct.id}"), false,
                      ct.user.ugid, ct.gid_map.ns_to_host(0)]
                   ])
    end

    # @return [Array]
    def abs_all_cgroup_paths
      abs_group_cgroup_paths + abs_ct_cgroup_paths
    end

    def to_abs_paths(rel_paths)
      rel_paths.map do |path, req, *args|
        [File.join(CGroup::FS, CGroup.real_subsystem('devices'), path), req, *args]
      end
    end

    # @param cgpath [String] absolute cgroup path
    # @param create [Boolean] create the cgroup or not
    # @return [Boolean] `true` if the cgroup exists or was created
    def prepare_cgroup(cgpath, create)
      exists = Dir.exist?(cgpath)

      if exists
        true

      elsif create
        begin
          Dir.mkdir(cgpath)
        rescue Errno::EEXIST
          true
        end

        # uid/gid is inherited from the parent cgroup
        st = File.stat(File.dirname(cgpath))
        File.chown(st.uid, st.gid, cgpath)

      else
        false
      end
    end
  end
end
