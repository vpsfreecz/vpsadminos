import ../../make-test.nix (pkgs: {
  name = "zfs-ugidmap";

  description = ''
    Test ZFS UID/GID mapping patch

    These tests are in form of shell scripts, they have been taken from the
    patch which added them to the ZFS test suite.
  '';

  machine = import ../../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_service("pool-tank")

    test_dir = "/ugidmap"
    test_run = File.join(test_dir, "run.sh")

    # Deploy tests
    machine.mkdir(test_dir)

    tests = %w(defaults properties send-recv mappings)
    files = %w(run setup) + tests

    files.each do |name|
      machine.push_file(
        File.join("${./ugidmap}", "#{name}.sh"),
        File.join(test_dir, "#{name}.sh"),
      )
    end

    machine.succeeds("chmod +x #{test_run}")

    # Run setup
    machine.succeeds("#{test_run} #{test_dir} setup")

    # Run tests
    tests.each do |name|
      machine.succeeds("#{test_run} #{test_dir} #{name}")
    end
  '';
})
