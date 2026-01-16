import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctl-ct-map-mode";

    description = ''
      Test osctl ct map mode
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      # Prepare a container
      machine.all_succeed(
        "osctl ct new --distribution alpine testct",
        "osctl ct unset start-menu testct"
      )

      # Default value
      _, default_mode = machine.succeeds("osctl ct show -H -o map_mode testct")

      if default_mode.strip != 'native'
        fail "expected default map_mode=native, got #{default_mode.inspect}"
      end

      # Customize map mode on creation
      machine.all_succeed(
        "osctl ct del testct",
        "osctl ct new --distribution alpine --map-mode zfs testct",
        "osctl ct unset start-menu testct"
      )

      _, custom_mode = machine.succeeds("osctl ct show -H -o map_mode testct")

      if custom_mode.strip != 'zfs'
        fail "expected map_mode=zfs, got #{custom_mode.inspect}"
      end

      # Change mode
      machine.succeeds("osctl ct set map-mode testct native")

      _, changed_mode = machine.succeeds("osctl ct show -H -o map_mode testct")

      if changed_mode.strip != 'native'
        fail "expected map_mode=native, got #{changed_mode.inspect}"
      end

      # CLI checks
      machine.all_fail(
        "osctl ct set map-mode",
        "osctl ct set map-mode testct",
        "osctl ct set map-mode testct woah",
        "osctl ct set map-mode testct native woah"
      )
      machine.succeeds("osctl ct start testct")
      machine.fails("osctl ct set map-mode testct zfs")
      machine.all_succeed(
        "osctl ct stop testct",
        "osctl ct set map-mode testct native",
        "osctl ct set map-mode testct native",
        "osctl ct del testct"
      )

      # Per-mode tests
      %w[native zfs].each do |mode|
        machine.all_succeed(
          "osctl ct new --distribution debian --map-mode #{mode} testct",
          "osctl ct unset start-menu testct"
        )

        _, check_mode = machine.succeeds("osctl ct show -H -o map_mode testct")

        if check_mode.strip != mode
          fail "expected map_mode=#{mode}, got #{custom_mode.inspect}"
        end

        machine.succeeds("osctl ct start testct")

        _, running = machine.succeeds("osctl ct exec testct systemctl is-system-running --wait")

        if running.strip != 'running'
          fail "expected the system to be running, got #{running.inspect}"
        end

        # Permissions of root dataset
        _, inside_owner = machine.succeeds("osctl ct exec testct stat -c %u:%g /var")

        if inside_owner.strip != '0:0'
          fail "expected  inside owner to be 0:0, got #{inside_owner.inspect}"
        end

        _, rootfs_str = machine.succeeds("osctl ct show -H -o rootfs testct")
        rootfs = rootfs_str.strip

        _, host_owner = machine.succeeds("stat -c %u:%g #{rootfs}/var")

        _, dataset_str = machine.succeeds("osctl ct show -H -o dataset testct")
        dataset = dataset_str.strip

        _, zfs_get = machine.succeeds("zfs get -H -o value uidmap,gidmap #{dataset}")
        zfs_props = zfs_get.strip.split

        if mode == 'native'
          if host_owner.strip != '0:0'
            fail "expected host owner to be 0:0, got #{host_owner.inspect}"
          elsif zfs_props != %w[none none]
            fail "expected uidmap/gidmap to be none, got #{zfs_props.inspect}"
          end

        elsif mode == 'zfs'
          uid, gid = host_owner.strip.split(':').map(&:to_i)

          if uid <= 0 || gid <= 0
            fail "expected host owner to be shifted, got #{host_owner.inspect}"
          elsif zfs_props == %w[none none]
            fail "expected uidmap/gidmap to be set, got #{zfs_props.inspect}"
          end
        end

        # Permissions of a subdataset
        machine.all_succeed(
          "osctl ct dataset new testct mysubdataset",
          "osctl ct exec testct /bin/sh -c 'echo hello > /mysubdataset/hello.txt'"
        )

        _, sub_inside_owner = machine.succeeds("osctl ct exec testct stat -c %u:%g /mysubdataset/hello.txt")

        if sub_inside_owner.strip != '0:0'
          fail "expected subdataset inside owner to be 0:0, got #{sub_inside_owner.inspect}"
        end

        subdataset = File.join(dataset, 'mysubdataset')

        _, subdataset_mountpoint_str = machine.succeeds("zfs get -H -o value mountpoint #{subdataset}")
        subdataset_mountpoint = subdataset_mountpoint_str.strip

        _, sub_host_owner = machine.succeeds("stat -c %u:%g #{subdataset_mountpoint}/private/hello.txt")

        _, sub_zfs_get = machine.succeeds("zfs get -H -o value uidmap,gidmap #{subdataset}")
        sub_zfs_props = sub_zfs_get.strip.split

        if mode == 'native'
          if sub_host_owner.strip != '0:0'
            fail "expected subdataset host owner to be 0:0, got #{sub_host_owner.inspect}"
          elsif sub_zfs_props != %w[none none]
            fail "expected subdataset uidmap/gidmap to be none, got #{sub_zfs_props.inspect}"
          end

        elsif mode == 'zfs'
          uid, gid = sub_host_owner.strip.split(':').map(&:to_i)

          if uid <= 0 || gid <= 0
            fail "expected subdataset host owner to be shifted, got #{sub_host_owner.inspect}"
          elsif sub_zfs_props == %w[none none]
            fail "expected subdataset uidmap/gidmap to be set, got #{sub_zfs_props.inspect}"
          end
        end

        # Check the subdataset is mounted after restart
        machine.succeeds("osctl ct restart testct")

        _, hello = machine.succeeds("osctl ct cat testct /mysubdataset/hello.txt")

        if hello.strip != 'hello'
          fail "/mysubdataset/hello.txt not found, expected 'hello', got #{hello.inspect}"
        end

        machine.all_succeed(
          "osctl healthcheck -a",
          "osctl ct del -f testct"
        )
      end
    '';
  }
)
