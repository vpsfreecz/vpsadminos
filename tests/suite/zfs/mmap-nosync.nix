import ../../make-test.nix (
  { pkgs }:
  let
    mkScripts =
      { file, size }:
      {
        writer = pkgs.writeScript "mmap-writer.py" ''
          #!/usr/bin/env python3

          import sys
          import mmap
          import hashlib

          FILE     = "${file}"
          SIZE     = ${toString size}
          CHK_FILE = FILE + ".sha256"

          with open(FILE, "wb") as f:
              f.truncate(SIZE)

          with open(FILE, "r+b") as f:
              mm = mmap.mmap(
                  f.fileno(),
                  length=SIZE,
                  flags=mmap.MAP_SHARED,
                  prot=mmap.PROT_READ | mmap.PROT_WRITE
              )

              for i in range(SIZE):
                  mm[i] = i & 0xFF

              # Explicitly avoiding msync()
              # mm.flush()

              mm.close()

          digest = hashlib.sha256(open(FILE, "rb").read()).hexdigest()
          with open(CHK_FILE, "w") as hf:
              hf.write(digest + "\n")

          print(f"Wrote {SIZE} bytes to {FILE}")
          print(f"SHA-256 saved in {CHK_FILE}: {digest}")
        '';

        reader = pkgs.writeScript "mmap-reader.py" ''
          #!/usr/bin/env python3

          import os
          import sys
          import mmap
          import hashlib

          FILE     = "${file}"
          CHK_FILE = FILE + ".sha256"

          if not os.path.isfile(FILE):
              print(f"File {FILE} not found", file=sys.stderr)
              sys.exit(1)

          with open(FILE, "rb") as f:
              mm = mmap.mmap(f.fileno(), length=0, access=mmap.ACCESS_READ)
              digest = hashlib.sha256(mm).hexdigest()
              mm.close()

          expected = open(CHK_FILE).read().strip()

          if digest == expected:
              print("SUCCESS: Content matches (SHA-256 {})".format(digest))
              sys.exit(0)
          else:
              print("FAILURE: Checksum mismatch!")
              print(" expected:", expected)
              print("   actual:", digest)
              sys.exit(1)
        '';
      };

    scripts = mkScripts {
      file = "/data/mmap_test.bin";
      size = 8 * 1024 * 1024;
    };
  in
  {
    name = "zfs-mmap-nosync";

    description = ''
      Test that data written using mmap() without msync() are persisted

      This checks for regression on a bug where data written using mmap() with
      MAP_SHARED and without msync() before munmap() were saved only to memory,
      but never written out to disk. Only pools with xattr=dir and acltype=posix
      were affected.

      The Bug and fix was introduced by ZFS commit
      "Linux: O_TMPFILE and insert inode hash rework", example broken ZFS commit
      is e.g. e81cc7c3efd78a90092e60d239eb93b9174bbf7e.

      Example available-kernels.nix fragment:

      ```
      "6.9.12-3" = {
        rev = "43566453ad31b9fa8e43fb3d48eb8e0bbae93ba5";
        sha256 = "sha256-/XfRopmX6enUzAnFXoxOvMhOfiaPj4MDwVVmRl3a+og=";
        zfs = {
          rev = "e81cc7c3efd78a90092e60d239eb93b9174bbf7e";
          sha256 = "sha256-NJwYoTgi3ahis7kzlrjycM7IlDZx2eZFcWGrB0P+0h8=";
        };
      };
      ```

      and then use `boot.kernelVersion = "6.9.12-3";`. The bug was however first
      introduced to kernel 6.10 and only then backported to 6.9.
    '';

    tags = [
      "ci"
      "regression"
    ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool('tank')

      variants = {
        # This is the problematic scenario
        'xattr-dir' => %w[xattr=dir acltype=posix],

        # Check newer xattr setting just in case
        'xattr-on' => %w[xattr=on acltype=posix]
      }

      machine.mkdir('/scripts')
      machine.push_file("${scripts.writer}", "/scripts/writer.py")

      cts = variants.map do |name, properties|
        testct = get_container_id(name)

        machine.all_succeed(
          "osctl ct new --distribution alpine #{properties.map { |v| "--zfs-property #{v}" }.join(' ')} #{testct}",
          "osctl ct unset start-menu #{testct}",
          "osctl ct netif new bridge --link lxcbr0 #{testct} eth0",
          "osctl ct start #{testct}"
        )

        machine.wait_until_container_online(testct, timeout: 60)

        container_apk(machine, testct, 'add', 'python3', name: "Install Python in #{testct}")

        machine.all_succeed(
          "osctl ct exec #{testct} mkdir /data",
          "osctl ct runscript #{testct} /scripts/writer.py"
        )

        testct
      end

      machine.succeeds('sync')

      machine.kill
      machine.wait_for_osctl_pool('tank')

      machine.mkdir('/scripts')
      machine.push_file("${scripts.reader}", "/scripts/reader.py")

      cts.each do |testct|
        # When the bug is present, the script itself might fail to run, because
        # apk installs packages in this way, so the python3 interpreter itself
        # may be broken.
        machine.all_succeed(
          "osctl ct start #{testct}",
          "osctl ct runscript #{testct} /scripts/reader.py"
        )
      end
    '';
  }
)
