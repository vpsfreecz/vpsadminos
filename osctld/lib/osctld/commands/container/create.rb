module OsCtld
  class Commands::Container::Create < Commands::Base
    handle :ct_create

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      ct = Container.new(opts[:id], opts[:user], load: false)

      ct.user.inclusively do
        ct.exclusively do
          return error('container already exists') if ContainerList.contains?(ct.id)

          zfs(:create, nil, ct.dataset)
          Dir.mkdir(ct.rootfs, 0750)

          syscmd("tar -xzf #{opts[:template]} -C #{ct.rootfs}")

          zfs(:unmount, nil, ct.dataset)
          zfs(:set, "uidoffset=#{ct.uid_offset} gidoffset=#{ct.gid_offset}", ct.dataset)
          zfs(:mount, nil, ct.dataset)

          distribution, version, *_ = File.basename(opts[:template]).split('-')

          ct.configure(
            distribution,
            version,
            Hash[ opts[:route_via].map { |k,v| [k.to_s.to_i, v] } ]
          )

          Template.render_to('ct/config', {
            distribution: distribution,
            ct: ct,
            hook_start_host: OsCtld::hook_run('ct-start'),
          }, ct.lxc_config_path)

          Template.render_to('ct/network', {
            hook_veth_up: OsCtld::hook_run('veth-up'),
            hook_veth_down: OsCtld::hook_run('veth-down'),
          }, ct.lxc_config_path('network'))

          ContainerList.add(ct)
        end
      end

      call_cmd(Commands::User::LxcUsernet)

      # Create dataset
      # Extract template
      # Set UID/GID offset
      # Create LXC config file
      # Create VPS config for osctl
      # Ensure writable log file
      # Register to ContainerList

      ok
    end
  end
end
