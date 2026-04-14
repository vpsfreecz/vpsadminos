import ../../make-test.nix (
  { pkgs }:
  let
    reproducer = pkgs.writeScript "block-cloning-reproducer.sh" ''
      #!/bin/sh
      set -eu

      pool="$1"
      root="/''${pool}-repro"
      dataset="''${pool}/repro"

      cleanup() {
        set +e
        zfs destroy -r "''${dataset}" >/dev/null 2>&1 || true
      }

      trap cleanup EXIT INT TERM

      zfs destroy -r "''${dataset}" >/dev/null 2>&1 || true
      zfs create -o mountpoint="''${root}" "''${dataset}"

      sample="''${root}/sample.txt"
      bad_src="$(mktemp -p "''${root}")"
      before_copy="''${root}/sample-before-md5-cp"
      after_copy="''${root}/sample-after-md5-cp"

      awk '
        BEGIN {
          while (length(data) < 3424) {
            data = data "PermitRootLogin yes\n"
            data = data "PasswordAuthentication yes\n"
            data = data "UsePAM yes\n"
            data = data "Subsystem sftp internal-sftp\n"
          }

          printf "%s", substr(data, 1, 3424)
        }
      ' > "''${sample}"

      rm -f "''${before_copy}" "''${after_copy}"

      sample_create_debug="$(cp --debug -aZ "''${sample}" "''${bad_src}" 2>&1)"
      printf '%s\n' "''${sample_create_debug}"

      sample_create_reflink=no
      if printf '%s\n' "''${sample_create_debug}" | grep -q 'reflink: yes'; then
        sample_create_reflink=yes
      fi

      cp "''${bad_src}" "''${before_copy}"
      md5sum "''${bad_src}" >/tmp/sample-bad-src.md5
      cp "''${bad_src}" "''${after_copy}"

      sample_hash="$(sha256sum "''${sample}" | awk '{print $1}')"
      zero_hash="$(dd if=/dev/zero bs="$(stat -c %s "''${sample}")" count=1 status=none | sha256sum | awk '{print $1}')"
      bad_src_hash="$(sha256sum "''${bad_src}" | awk '{print $1}')"
      before_copy_hash="$(sha256sum "''${before_copy}" | awk '{print $1}')"
      after_copy_hash="$(sha256sum "''${after_copy}" | awk '{print $1}')"

      echo "BLOCK_CLONING_SAMPLE_SIZE=$(stat -c %s "''${sample}")"
      echo "BLOCK_CLONING_SAMPLE_CREATE_REFLINK=''${sample_create_reflink}"
      echo "BLOCK_CLONING_SAMPLE_HASH=''${sample_hash}"
      echo "BLOCK_CLONING_ZERO_HASH=''${zero_hash}"
      echo "BLOCK_CLONING_SAMPLE_BAD_SRC_HASH=''${bad_src_hash}"
      echo "BLOCK_CLONING_SAMPLE_BEFORE_MD5_CP_HASH=''${before_copy_hash}"
      echo "BLOCK_CLONING_SAMPLE_AFTER_MD5_CP_HASH=''${after_copy_hash}"

      if [ "''${before_copy_hash}" = "''${sample_hash}" ] \
         && [ "''${after_copy_hash}" = "''${sample_hash}" ]; then
        echo "BLOCK_CLONING_RESULT=clean"
        exit 0
      fi

      if [ "''${before_copy_hash}" = "''${sample_hash}" ] \
         && [ "''${after_copy_hash}" = "''${zero_hash}" ]; then
        echo "BLOCK_CLONING_RESULT=corrupt"
        exit 42
      fi

      echo "BLOCK_CLONING_RESULT=unexpected"
      exit 43
    '';
  in
  {
    name = "zfs-block-cloning-corruption";

    description = ''
      Reproduce block-cloning corruption with native userspace on ZFS

      The test creates two pools:

      1. the default test pool `tank`, where block cloning is disabled
      2. a second pool `clone`, where block cloning is enabled

      On each pool, the test runs the minimal sequence that reproduces the
      corruption:

      1. create a regular text file
      2. `cp -aZ` it into an existing `mktemp` path
      3. `cp` that reflink-created file before any checksum pass
      4. run `md5sum` on the reflink-created source
      5. `cp` the same source again

      The test expects:

      1. both copies stay correct on `tank`
      2. the pre-`md5sum` copy stays correct on `clone`
      3. the post-`md5sum` copy on `clone` becomes an all-zero file

      This is a narrower reproducer than the original `openssh-server`/`ucf`
      path and shows that the corruption does not require `debootstrap` or
      Debian package binaries.
    '';

    tags = [
      "ci"
      "regression"
    ];

    machine = {
      disks = [
        {
          type = "file";
          device = "{machine}-sda.img";
          size = "20G";
        }
        {
          type = "file";
          device = "{machine}-sdb.img";
          size = "20G";
        }
      ];

      config =
        { lib, ... }:
        {
          boot.qemu.memory = 8 * 1024;

          boot.zfs.pools = {
            tank = {
              layout = [
                { devices = [ "sda" ]; }
              ];
              importAttempts = lib.mkDefault 3;
              doCreate = true;
              install = true;
              properties."feature@block_cloning" = "disabled";
            };

            clone = {
              layout = [
                { devices = [ "sdb" ]; }
              ];
              importAttempts = lib.mkDefault 3;
              doCreate = true;
              install = true;
              properties."feature@block_cloning" = "enabled";
            };
          };

          os.channel-registration.enable = true;
        };
    };

    testScript = ''
      def run_reproducer(pool)
        machine.execute("/scripts/reproducer.sh #{pool}", timeout: 2 * 60 * 60)
      end

      def output_value(output, key)
        match = output.match(/^#{Regexp.escape(key)}=(.+)$/)
        raise "missing #{key} in output:\n#{output}" unless match
        match[1]
      end

      describe 'ZFS block-cloning corruption' do
        before(:context) do
          machine.start
          machine.wait_for_zpool('tank')
          machine.wait_for_osctl_pool('tank')
          machine.wait_for_zpool('clone')
          machine.wait_for_osctl_pool('clone')
          machine.wait_until_online

          machine.mkdir('/scripts')
          machine.push_file("${reproducer}", '/scripts/reproducer.sh')

          @tank_feature = machine.succeeds("zpool get -H -o value feature@block_cloning tank")[1].strip
          @clone_feature = machine.succeeds("zpool get -H -o value feature@block_cloning clone")[1].strip

          @tank_status, @tank_output = run_reproducer('tank')
          @clone_status, @clone_output = run_reproducer('clone')

          @tank_sample_hash = output_value(@tank_output, 'BLOCK_CLONING_SAMPLE_HASH')
          @tank_zero_hash = output_value(@tank_output, 'BLOCK_CLONING_ZERO_HASH')
          @clone_sample_hash = output_value(@clone_output, 'BLOCK_CLONING_SAMPLE_HASH')
          @clone_zero_hash = output_value(@clone_output, 'BLOCK_CLONING_ZERO_HASH')
        end

        it 'uses the expected block-cloning pool properties' do
          expect(@tank_feature).to eq('disabled')
          expect(@clone_feature).to eq('enabled')
        end

        it 'stays clean on the default pool' do
          expect(@tank_status).to eq(0)
          expect(@tank_output).to include('BLOCK_CLONING_RESULT=clean')
          expect(output_value(@tank_output, 'BLOCK_CLONING_SAMPLE_BAD_SRC_HASH')).to eq(@tank_sample_hash)
          expect(output_value(@tank_output, 'BLOCK_CLONING_SAMPLE_BEFORE_MD5_CP_HASH')).to eq(@tank_sample_hash)
          expect(output_value(@tank_output, 'BLOCK_CLONING_SAMPLE_AFTER_MD5_CP_HASH')).to eq(@tank_sample_hash)
        end

        it 'does not reflink on the default pool' do
          expect(@tank_output).to include('BLOCK_CLONING_SAMPLE_CREATE_REFLINK=no')
        end

        it 'reproduces md5sum-triggered corruption on the block-cloning pool' do
          expect(@clone_sample_hash).to eq(@tank_sample_hash)
          expect(@clone_zero_hash).to eq(@tank_zero_hash)
          expect(@clone_status).to eq(42)
          expect(@clone_output).to include('BLOCK_CLONING_RESULT=corrupt')
          expect(output_value(@clone_output, 'BLOCK_CLONING_SAMPLE_BAD_SRC_HASH')).to eq(@clone_sample_hash)
          expect(output_value(@clone_output, 'BLOCK_CLONING_SAMPLE_BEFORE_MD5_CP_HASH')).to eq(@clone_sample_hash)
          expect(output_value(@clone_output, 'BLOCK_CLONING_SAMPLE_AFTER_MD5_CP_HASH')).to eq(@clone_zero_hash)
        end

        it 'uses reflink on the block-cloning pool' do
          expect(@clone_output).to include('BLOCK_CLONING_SAMPLE_CREATE_REFLINK=yes')
        end

        it 'does not fail for an unexpected reason on the block-cloning pool' do
          expect(@clone_output).not_to include('BLOCK_CLONING_RESULT=unexpected')
        end
      end
    '';
  }
)
