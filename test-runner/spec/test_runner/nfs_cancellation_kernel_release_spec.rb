# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'timeout'
require 'tmpdir'

# This regression's subject is a Nix-generated shell assertion, not a Ruby class.
RSpec.describe 'NFS cancellation running kernel assertion' do # rubocop:disable RSpec/DescribeClass
  let(:stable_metadata) { evaluate_stable_metadata }

  let(:teardown_script) do
    source = File.join(REPO_ROOT, 'tests/suite/osctl/nfs-cancellation-common.nix')
    expression = <<~NIX
      (import (builtins.toPath #{source.to_json}) {
        name = "osctl-nfs-cancellation";
        description = "";
        expectedKernelRelease = #{stable_metadata.fetch('release').to_json};
        expectedKernelRevision = #{stable_metadata.fetch('revision').to_json};
        machine = {};
        pkgs = {
          coreutils = "/unused-coreutils";
          kmod = "/unused-kmod";
          pkgsStatic.stdenv.mkDerivation = _: "/unused-program";
          writeScript = _: _: "/unused-dirty-init-script";
          writeShellScript = _: _: "/unused-nfs-blocked-modprobe";
          ruby = "/unused-ruby";
          util-linux = "/unused-util-linux";
          lib.optionalString = condition: value: if condition then value else "";
        };
      }).testScript
    NIX
    output, error, status = Open3.capture3(
      { 'VPSADMINOS_NFS_CANCELLATION_EXAMPLE_FILTER' => '' },
      'nix-instantiate', '--eval', '--strict', '--json', '--expr', expression
    )
    raise "NFS test script evaluation failed: #{error}" unless status.success?

    JSON.parse(output)
  end

  let(:teardown_harness_class) do
    Class.new do
      class << self
        def before(*) end
        def after(*) end
        def describe(*) end
      end
    end.tap do |klass|
      klass.class_eval(teardown_script, 'nfs-cancellation-common.nix')
    end
  end

  def wrapper_source
    File.read(File.join(REPO_ROOT, 'tests/suite/osctl/nfs-cancellation.nix'))
  end

  def common_source
    File.read(File.join(REPO_ROOT, 'tests/suite/osctl/nfs-cancellation-common.nix'))
  end

  def setup_harness_class
    Class.new do
      include RSpec::Matchers
      attr_accessor :machine

      class << self
        attr_reader :suite_setup

        def before(scope, &block)
          @suite_setup = block if scope == :suite
        end

        def after(*) end
        def describe(*) end
      end

      def container_apk(*) end
    end.tap do |klass|
      klass.class_eval(teardown_script, 'nfs-cancellation-common.nix')
    end
  end

  def example_filter_harness_class(script)
    Class.new do
      class << self
        attr_reader :examples

        def before(*) end
        def after(*) end
        def describe(*) end

        def it(message, pending: false, skip: false, &block)
          example(message, pending: pending, skip: skip, &block)
        end

        def example(message, pending: false, skip: false, &)
          @examples ||= []
          @examples << { message: message, pending: pending, skip: skip }
        end
      end
    end.tap do |klass|
      klass.class_eval(script, 'nfs-cancellation-common.nix')
    end
  end

  def collect_example_messages(script)
    Class.new do
      class << self
        attr_reader :examples

        def before(*) end
        def after(*) end

        def describe(*, &block)
          class_eval(&block)
        end

        def it(message, **, &)
          @examples ||= []
          @examples << message
        end
      end
    end.tap do |klass|
      klass.class_eval(script, 'nfs-cancellation-common.nix')
    end.examples
  end

  def evaluate_stable_metadata
    source = File.join(REPO_ROOT, 'os/packages/linux/available-kernels.nix')
    expression = <<~NIX
      let
        lib = import <nixpkgs/lib>;
        available = import (builtins.toPath #{source.to_json}) { inherit lib; };
        selected = available.kernels.${available.stableKernelVersion};
      in {
        release = available.stableKernelVersion;
        revision = selected.rev;
        sha256 = selected.sha256;
        zfsRevision = selected.zfs.rev;
        zfsSha256 = selected.zfs.sha256;
        zfsPatches = map toString (selected.zfs.patches or []);
      }
    NIX
    output, error, status = Open3.capture3(
      'nix-instantiate', '--eval', '--strict', '--json', '--expr', expression
    )
    raise "stable kernel metadata evaluation failed: #{error}" unless status.success?

    JSON.parse(output)
  end

  def shutdown_unmount_source
    File.read(
      File.join(
        REPO_ROOT,
        'tests/suite/osctl/nfs-cancellation/shutdown-unmount.c'
      )
    )
  end

  def compile_shutdown_unmount(binary)
    source = File.join(
      REPO_ROOT,
      'tests/suite/osctl/nfs-cancellation/shutdown-unmount.c'
    )
    Open3.capture3(
      ENV.fetch('CC', 'cc'),
      '-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror',
      source, '-o', binary
    )
  end

  def evaluate_machine_composition
    source = File.join(REPO_ROOT, 'tests/suite/osctl/nfs-cancellation-common.nix')
    expression = <<~NIX
      (import (builtins.toPath #{source.to_json}) {
        name = "osctl-nfs-cancellation";
        description = "";
        expectedKernelRelease = #{stable_metadata.fetch('release').to_json};
        expectedKernelRevision = #{stable_metadata.fetch('revision').to_json};
        machine = {
          marker = "preserved";
          modules = [ { existing.option = "preserved"; } ];
        };
        pkgs = {
          coreutils = "/unused-coreutils";
          kmod = "/unused-kmod";
          pkgsStatic.stdenv.mkDerivation = _: "/unused-program";
          writeScript = _: _: "/unused-dirty-init-script";
          writeShellScript = _: _: "/unused-nfs-blocked-modprobe";
          ruby = "/unused-ruby";
          util-linux = "/unused-util-linux";
          lib.optionalString = condition: value: if condition then value else "";
        };
      }).machine
    NIX
    output, error, status = Open3.capture3('nix-instantiate', '--eval', '--strict', '--json', '--expr', expression)
    raise "NFS machine composition evaluation failed: #{error}" unless status.success?

    JSON.parse(output)
  end

  def evaluate_blocked_modprobe_script
    source = File.join(REPO_ROOT, 'tests/suite/osctl/nfs-cancellation-common.nix')
    sleep_path = ENV.fetch('PATH').split(File::PATH_SEPARATOR)
                    .map { |path| File.join(path, 'sleep') }
                    .find { |path| File.executable?(path) }
    raise 'sleep is unavailable for the NFS helper regression' unless sleep_path

    coreutils = File.dirname(sleep_path, 2)
    expression = <<~NIX
      let
        fixture = import (builtins.toPath #{source.to_json}) {
          name = "osctl-nfs-cancellation";
          description = "";
          expectedKernelRelease = #{stable_metadata.fetch('release').to_json};
          expectedKernelRevision = #{stable_metadata.fetch('revision').to_json};
          machine = {};
          pkgs = {
            coreutils = #{coreutils.to_json};
            kmod = "/unused-kmod";
            pkgsStatic.stdenv.mkDerivation = _: "/unused-program";
            writeScript = _: _: "/unused-dirty-init-script";
            writeShellScript = _: body: body;
            ruby = "/unused-ruby";
            util-linux = "/unused-util-linux";
            lib.optionalString = condition: value: if condition then value else "";
          };
        };
        module = builtins.elemAt fixture.machine.modules 0;
      in builtins.elemAt module.system.extraDependencies 2
    NIX
    output, error, status = Open3.capture3(
      'nix-instantiate', '--eval', '--strict', '--json', '--expr', expression
    )
    raise "NFS modprobe helper evaluation failed: #{error}" unless status.success?

    JSON.parse(output)
  end

  def evaluate_fixture_script(example_filter: '')
    source = File.join(REPO_ROOT, 'tests/suite/osctl/nfs-cancellation-common.nix')
    expression = <<~NIX
      (import (builtins.toPath #{source.to_json}) {
        name = "osctl-nfs-cancellation";
        description = "";
        expectedKernelRelease = #{stable_metadata.fetch('release').to_json};
        expectedKernelRevision = #{stable_metadata.fetch('revision').to_json};
        machine = {};
        pkgs = {
          coreutils = "/unused-coreutils";
          kmod = "/unused-kmod";
          pkgsStatic.stdenv.mkDerivation = _: "/unused-program";
          writeScript = _: _: "/unused-dirty-init-script";
          writeShellScript = _: _: "/unused-nfs-blocked-modprobe";
          ruby = "/unused-ruby";
          util-linux = "/unused-util-linux";
          lib.optionalString = condition: value: if condition then value else "";
        };
      }).testScript
    NIX
    output, error, status = Open3.capture3(
      { 'VPSADMINOS_NFS_CANCELLATION_EXAMPLE_FILTER' => example_filter },
      'nix-instantiate', '--eval', '--strict', '--json', '--expr', expression
    )
    raise "NFS fixture evaluation failed: #{error}" unless status.success?

    JSON.parse(output)
  end

  shared_examples 'an exact release assertion' do
    let(:guard) do
      source = File.join(REPO_ROOT, 'tests/suite/osctl/nfs-cancellation-common.nix')
      expression = <<~NIX
        (import (builtins.toPath #{source.to_json}) {
          name = "osctl-nfs-cancellation";
          expectedKernelRelease = #{stable_metadata.fetch('release').to_json};
          expectedKernelRevision = #{stable_metadata.fetch('revision').to_json};
          description = "";
          machine = {};
          pkgs = {
            coreutils = "/unused-coreutils";
            kmod = "/unused-kmod";
            pkgsStatic.stdenv.mkDerivation = _: "/unused-dirty-init";
            writeScript = _: _: "/unused-dirty-init-script";
            writeShellScript = _: _: "/unused-nfs-blocked-modprobe";
            ruby = "/unused-ruby";
            util-linux = "/unused-util-linux";
            lib.optionalString = condition: value: if condition then value else "";
          };
        }).testScript
      NIX
      output, error, status = Open3.capture3(
        { 'VPSADMINOS_NFS_CANCELLATION_EXAMPLE_FILTER' => '' },
        'nix-instantiate', '--eval', '--strict', '--json', '--expr', expression
      )
      raise "NFS test script evaluation failed: #{error}" unless status.success?

      JSON.parse(output).match(/machine\.succeeds\('([^']*uname -r[^']*)'\)/)[1]
    end

    it 'accepts only the selected stable release' do
      expected_release = stable_metadata.fetch('release')
      candidates = %w[6.12.95 6.12.95.6 6.12.95.7 6.12.109 6.12.110]
      (candidates + [expected_release]).uniq.each do |release|
        command = "uname() { printf '%s\\n' #{release.shellescape}; }; #{guard}"
        output, error, status = Open3.capture3('sh', '-c', command)

        expect(error).to eq('')
        expect(status.success?).to eq(release == expected_release)
        expect(output).to eq(release == expected_release ? "#{release}\n" : '')
      end
    end
  end

  context 'with the canonical stable kernel' do
    it_behaves_like 'an exact release assertion'
  end

  it 'keeps host authority while cloning the target mount for teardown' do
    harness = teardown_harness_class.new
    expect(harness.nfs_namespace_control(123, enter_mount: true))
      .to eq(
        'PATH=/usr/sbin:/usr/bin:/sbin:/bin ' \
        '/unused-util-linux/bin/nsenter -t 123 ' \
        '--user --setuid 0 --setgid 0 --keep-caps --net --mount ' \
        '--root --wd=/run -- /usr/bin/unshare --mount /bin/sh -ec'
      )
    expect(harness.nfs_namespace_control(123, enter_mount: true, trace: true))
      .to end_with('/usr/bin/unshare --mount /bin/sh -exc')
    expect(teardown_script.scan('nfs_namespace_control(nfs1_init_pid, enter_mount: true)').length)
      .to eq(1)
    expect(teardown_script.scan(/nfs_namespace_control\([^,]+, enter_mount: true\)/).length)
      .to eq(1)

    transient = teardown_script
                .split('def transient_nfs_server_ids(init_pid)', 2).fetch(1)
                .split('def with_blocked_nfs_auth_module', 2).fetch(0)
    teardown = teardown_script
               .split('it "drains an admitted shutdown writer before final unmount" do', 2).fetch(1)
               .split('if version == \'3\'', 2).fetch(0)
    partial_init = teardown_script
                   .split('it "releases a server after post-publication RPC auth setup fails" do', 2).fetch(1)
                   .split('it "cancels shared mounts on forced stop', 2).fetch(0)

    [transient, teardown, partial_init].each do |source|
      expect(source).to include('control = nfs_namespace_control(init_pid)')
      expect(source).not_to include('enter_mount: true')
    end
    expect(teardown).to include('exec /run/nfs-shutdown-unmount ')
    expect(teardown).to include(
      "/sys/fs/nfs/\#{mount_id}/shutdown \#{init_pid} /mnt/nfs"
    )

    shutdown_open = shutdown_unmount_source.index('fd = open(argv[1], O_WRONLY | O_CLOEXEC)')
    proc_open = shutdown_unmount_source.index('proc = open(path, O_PATH | O_DIRECTORY | O_CLOEXEC)')
    user_ns_open = shutdown_unmount_source.index(
      'user_ns = openat(proc, "ns/user", O_RDONLY | O_CLOEXEC)'
    )
    mount_ns_open = shutdown_unmount_source.index('ns = openat(proc, "ns/mnt", O_RDONLY | O_CLOEXEC)')
    expected_root_open = shutdown_unmount_source.index(
      'expected_root = openat(proc, "root", O_PATH | O_DIRECTORY | O_CLOEXEC)'
    )
    expected_root_stat = shutdown_unmount_source.index(
      'if (fstat(expected_root, &expected_root_stat))'
    )
    owner_lookup = shutdown_unmount_source.index('owner_user_ns = ioctl(ns, NS_GET_USERNS)')
    owner_stat = shutdown_unmount_source.index(
      'if (fstat(owner_user_ns, &owner_user_ns_stat))'
    )
    user_ns_stat = shutdown_unmount_source.index('if (fstat(user_ns, &user_ns_stat))')
    owner_authentication = shutdown_unmount_source.index(
      'owner_user_ns_stat.st_dev != user_ns_stat.st_dev'
    )
    owner_close = shutdown_unmount_source.index('if (close(owner_user_ns))')
    user_setns = shutdown_unmount_source.index('if (setns(user_ns, CLONE_NEWUSER))')
    root_group = shutdown_unmount_source.index('if (setresgid(0, 0, 0))')
    root_user = shutdown_unmount_source.index('if (setresuid(0, 0, 0))')
    user_ns_close = shutdown_unmount_source.index('if (close(user_ns))')
    mount_setns = shutdown_unmount_source.index('if (setns(ns, CLONE_NEWNS))')
    reopened_root_open = shutdown_unmount_source.index(
      'reopened_root = openat(proc, "root", O_PATH | O_DIRECTORY | O_CLOEXEC)'
    )
    reopened_root_stat = shutdown_unmount_source.index(
      'if (fstat(reopened_root, &reopened_root_stat))'
    )
    root_authentication = shutdown_unmount_source.index(
      'expected_root_stat.st_dev != reopened_root_stat.st_dev'
    )
    root_selection = shutdown_unmount_source.index(
      'if (fchdir(reopened_root) || chroot(".") || chdir("/"))'
    )
    clone = shutdown_unmount_source.index('if (unshare(CLONE_NEWNS))')
    propagation = shutdown_unmount_source.index(
      'if (mount(NULL, "/", NULL, MS_REC | MS_SLAVE, NULL))'
    )
    clone_unmount = shutdown_unmount_source.index('if (umount2(argv[3], 0))')
    writer = shutdown_unmount_source.index('writer = fork()')
    second_setns = shutdown_unmount_source.index('} else if (setns(ns, CLONE_NEWNS))')
    final_unmount = shutdown_unmount_source.index(
      '} else if (umount2(argv[3], 0))'
    )

    expect(
      [
        shutdown_open,
        proc_open,
        user_ns_open,
        mount_ns_open,
        expected_root_open,
        expected_root_stat,
        owner_lookup,
        owner_stat,
        user_ns_stat,
        owner_authentication,
        owner_close,
        user_setns,
        root_group,
        root_user,
        user_ns_close,
        mount_setns,
        reopened_root_open,
        reopened_root_stat,
        root_authentication,
        root_selection,
        clone,
        propagation,
        clone_unmount,
        writer,
        second_setns,
        final_unmount
      ]
    ).to all(be_a(Integer))
    expect(shutdown_open).to be < proc_open
    expect(proc_open).to be < user_ns_open
    expect(user_ns_open).to be < mount_ns_open
    expect(mount_ns_open).to be < expected_root_open
    expect(expected_root_open).to be < expected_root_stat
    expect(expected_root_stat).to be < owner_lookup
    expect(owner_lookup).to be < owner_stat
    expect(owner_stat).to be < user_ns_stat
    expect(user_ns_stat).to be < owner_authentication
    expect(owner_authentication).to be < owner_close
    expect(owner_close).to be < user_setns
    expect(user_setns).to be < root_group
    expect(root_group).to be < root_user
    expect(root_user).to be < user_ns_close
    expect(user_ns_close).to be < mount_setns
    expect(mount_setns).to be < reopened_root_open
    expect(reopened_root_open).to be < reopened_root_stat
    expect(reopened_root_stat).to be < root_authentication
    expect(root_authentication).to be < root_selection
    expect(root_selection).to be < clone
    expect(clone).to be < propagation
    expect(propagation).to be < clone_unmount
    expect(clone_unmount).to be < writer
    expect(writer).to be < second_setns
    expect(second_setns).to be < final_unmount
    expect(shutdown_unmount_source).to include(
      'expected_root_stat.st_ino != reopened_root_stat.st_ino'
    )
    expect(shutdown_unmount_source).to include(
      'fail("authenticate reopened container root")'
    )
    expect(shutdown_unmount_source).to include('#include <linux/nsfs.h>')
    expect(shutdown_unmount_source).to include('#include <sys/ioctl.h>')
    expect(shutdown_unmount_source).to include(
      'owner_user_ns_stat.st_ino != user_ns_stat.st_ino'
    )
    expect(shutdown_unmount_source).to include(
      'fail("authenticate mount namespace owner")'
    )
    expect(shutdown_unmount_source).not_to include('fchdir(expected_root)')
    expect(shutdown_unmount_source).to include('pwrite(fd, "1\\n", 2, 0)')
    expect(shutdown_unmount_source).to include('errno == ENODEV')
    expect(shutdown_unmount_source).to include('!writes')
    expect(shutdown_unmount_source).to include(
      'printf("shutdown_writes=%lu unmounted=%d\\n", writes, !error)'
    )
    expect(teardown).to include('shutdown_writes=[1-9]\\d* unmounted=1')
    expect(teardown).to include('osctl ct exec nfs1 mountpoint -q /mnt/nfs')
    expect(teardown).to include('osctl ct exec nfs2 cat /mnt/nfs/')
  end

  it 'rejects non-EAGAIN results in the partial-callback helper mode' do
    mode_source = shutdown_unmount_source
                  .split('static int expect_eagain(const char *path)', 2).fetch(1)
                  .split('int main(int argc, char **argv)', 2).fetch(0)
    expect(mode_source.scan('open(').length).to eq(1)
    expect(mode_source.scan('pwrite(').length).to eq(1)
    expect(mode_source.scan('close(').length).to eq(1)
    expect(mode_source).to include('open(path, O_WRONLY | O_CLOEXEC)')
    expect(mode_source).to include('ret == -1 && write_errno == EAGAIN')
    expect(mode_source).to include('printf("partial_callback=eagain\\n")')
    expect(mode_source).to include('short shutdown write: %zd')

    Dir.mktmpdir('nfs-shutdown-unmount') do |dir|
      binary = File.join(dir, 'shutdown-unmount')
      output, error, status = compile_shutdown_unmount(binary)
      expect(status).to be_success
      expect(output).to eq('')
      expect(error).to eq('')

      ordinary = File.join(dir, 'ordinary-shutdown')
      File.write(ordinary, "0\n")
      output, error, status = Open3.capture3(
        binary, '--expect-eagain', ordinary
      )
      expect(status).not_to be_success
      expect(output).to eq('')
      expect(error).to eq("shutdown write unexpectedly succeeded\n")
      expect(File.read(ordinary)).to eq("1\n")

      output, error, status = Open3.capture3(
        binary, '--expect-eagain', '/dev/full'
      )
      expect(status).not_to be_success
      expect(output).to eq('')
      expect(error).to match(/write shutdown: .*space/i)
    end
  end

  it 'keeps the root owner while cancelling blocked work in the processless child namespace' do
    processless = teardown_script
                  .split('it "cancels an NFS mount in a processless child network namespace" do', 2).fetch(1)
                  .split('it "rejects new mounts and descendants after host terminal cancellation" do', 2).fetch(0)

    expect(processless).not_to include('osctl ct exec nfs1 umount /mnt/nfs')
    expect(processless).to include("start_writer(version, '/mnt/nfs-child')")
    expect(processless).to include('with_restored_nfs_client(version, before_restore: restore)')
    expect(processless).to include('nfs_namespace_path_control(held_net)')
    expect(processless).to include('/sys/fs/nfs/net/nfs_client/shutdown_tree')
  end

  it 'uses store-qualified namespace helpers and conditional suite cleanup' do
    harness = teardown_harness_class.new
    expect(harness.nfs_namespace_control(42))
      .to eq(
        '/unused-util-linux/bin/nsenter -t 42 --net ' \
        '/unused-util-linux/bin/unshare --mount sh -ec'
      )
    expect(harness.nfs_namespace_path_control('/run/example-netns'))
      .to eq(
        '/unused-util-linux/bin/nsenter --net=/run/example-netns ' \
        '/unused-util-linux/bin/unshare --mount sh -ec'
      )
    expect(teardown_script).to include(
      'if mountpoint -q /mnt/nfs; then umount /mnt/nfs; fi'
    )
    expect(teardown_script).to include('test -x /unused-util-linux/bin/nsenter')
    expect(teardown_script).to include('test -x /unused-util-linux/bin/unshare')
    expect(teardown_script).to include(
      '-t $(cat /run/osctl/exportfs/servers/server1/pid) -m -n'
    )
    expect(teardown_script).to include('/unused-util-linux/bin/unshare --mount true')
    expect(teardown_script).to include('test -x /usr/bin/unshare')
    expect(teardown_script).to include('test -x /bin/sh')
    expect(teardown_script).to include('test -r /proc/1/ns/mnt')
    expect(teardown_script).to include('test -r /proc/1/root')
    expect(teardown_script).to include('test -x ./nfs-shutdown-unmount')
    readiness = teardown_script
                .split('helpers_ready = machine.succeeds(', 2).fetch(1)
                .split("expect(helpers_ready).to eq('NFS_CONTAINER_NAMESPACE_HELPERS_READY')", 2).fetch(0)
    expect(readiness).to include(
      'mount --make-rslave /; mount -t sysfs sysfs /sys; '
    )
    expect(readiness).to include('echo NFS_CONTAINER_NAMESPACE_HELPERS_READY')
    propagation_mount = readiness.index('mount --make-rslave /')
    sysfs_mount = readiness.index('mount -t sysfs sysfs /sys')
    marker = readiness.index('echo NFS_CONTAINER_NAMESPACE_HELPERS_READY')
    expect(propagation_mount).to be < sysfs_mount
    expect(sysfs_mount).to be < marker
    expect(teardown_script).to include(
      "expect(helpers_ready).to eq('NFS_CONTAINER_NAMESPACE_HELPERS_READY')"
    )
    expect(teardown_script).not_to include('NFS_CONTAINER_NAMESPACE_HELPERS_READYn')
  end

  it 'retains fixture helpers without replacing machine fields or modules' do
    machine = evaluate_machine_composition
    expect(machine.fetch('marker')).to eq('preserved')
    expect(machine.fetch('modules')).to eq(
      [
        { 'existing' => { 'option' => 'preserved' } },
        {
          'system' => {
            'extraDependencies' => [
              '/unused-util-linux',
              '/unused-kmod',
              '/unused-nfs-blocked-modprobe'
            ]
          }
        }
      ]
    )
  end

  it 'renders the read-only namespace cancellation ABI gate' do
    script = evaluate_fixture_script
    rendered_commands = script.gsub(%q(\"), '"')
    expect(script).to include('for control in shutdown shutdown_tree')
    expect(rendered_commands).to include(
      'test "$(stat -c %a /sys/fs/nfs/net/nfs_client/$control)" = 600'
    )
    expect(rendered_commands).to include(
      'test "$(cat /sys/fs/nfs/net/nfs_client/$control)" = 0'
    )
    expect(script).to include('NFS_CANCELLATION_ABI_READY')
    expect(script).not_to include('> /sys/fs/nfs/net/nfs_client/$control')
    expect(script.index('NFS_CONTAINER_NAMESPACE_HELPERS_READY'))
      .to be < script.index('NFS_CANCELLATION_ABI_READY')
    expect(script.index('NFS_CANCELLATION_ABI_READY'))
      .to be < script.index('mkdir -p /srv/nfs-cancellation')
  end

  it 'retains the nfs1 init pid through the early ABI setup' do
    machine = Class.new do
      def start; end
      def wait_for_osctl_pool(*) end
      def wait_until_online; end
      def push_file(*) end
      def succeeds(*) end
      def all_succeed(*) end
    end.new
    setup_complete = Class.new(StandardError)
    commands = []
    harness_class = setup_harness_class
    harness = harness_class.new

    harness.machine = machine
    allow(machine).to receive(:succeeds) do |command, **|
      commands << command
      output = if command.include?('cat /sys/class/net/lxcbr0/address')
                 "02:00:00:00:00:01\n"
               elsif command.include?('osctl ct show -H -o init_pid nfs1')
                 "123\n"
               elsif command.include?('NFS_CONTAINER_NAMESPACE_HELPERS_READY')
                 "NFS_CONTAINER_NAMESPACE_HELPERS_READY\n"
               elsif command.include?('NFS_CANCELLATION_ABI_READY')
                 "NFS_CANCELLATION_ABI_READY\n"
               else
                 ''
               end
      [0, output]
    end
    allow(machine).to receive(:all_succeed) do |*commands_to_run|
      if commands_to_run.any? { |command| command.include?('mkdir -p /srv/nfs-cancellation') }
        raise setup_complete
      end
    end

    expect { harness.instance_exec(&harness_class.suite_setup) }
      .to raise_error(setup_complete)
    expect(commands.grep(/NFS_CANCELLATION_ABI_READY/).length).to eq(1)
  end

  it 'keeps normal examples intact and filters only either exact preflight message' do
    partial_init = 'releases a server after post-publication RPC auth setup fails'
    legacy_nlm = 'shuts down a legacy server before the first NLM lock'
    other = 'cancels shared mounts on forced stop'

    ['', 'not-a-known-example'].each do |filter|
      script = evaluate_fixture_script(example_filter: filter)
      expect(script).not_to include('default_order')
      harness = example_filter_harness_class(script)
      harness.it(partial_init, pending: true) { nil }
      harness.it(other, skip: true) { nil }
      expect(harness.examples).to eq(
        [
          { message: partial_init, pending: true, skip: false },
          { message: other, pending: false, skip: true }
        ]
      )
    end

    [partial_init, legacy_nlm].each do |filter|
      script = evaluate_fixture_script(example_filter: filter)
      harness = example_filter_harness_class(script)
      harness.it(filter, pending: true) { nil }
      harness.it(filter, skip: true) { nil }
      harness.it(other) { nil }
      expect(harness.examples).to eq(
        [
          { message: filter, pending: true, skip: false },
          { message: filter, pending: false, skip: true },
          { message: other, pending: false, skip: true }
        ]
      )
    end
  end

  it 'derives the stable release, source and ZFS tuple from one canonical object' do
    metadata = stable_metadata.values_at(
      'release', 'revision', 'sha256', 'zfsRevision', 'zfsSha256'
    )
    expect(metadata).to all(match(/\S/))
    expect(stable_metadata.fetch('zfsPatches')).not_to be_empty
    expect(wrapper_source).to include('inherit (availableKernels) stableKernelVersion;')
    expect(wrapper_source).to include(
      'stableKernel = availableKernels.kernels.${stableKernelVersion};'
    )
    expect(wrapper_source).to include('expectedKernelRelease = stableKernelVersion;')
    expect(wrapper_source).to include('expectedKernelRevision = stableKernel.rev;')
    expect(wrapper_source).to include(
      'boot.kernelVersion = lib.mkForce stableKernelVersion;'
    )
    metadata.each { |literal| expect(wrapper_source).not_to include(literal) }
    expect(wrapper_source).not_to include('mkKernel')
    expect(wrapper_source).not_to include('zfsBuiltin')
    expect(wrapper_source).not_to include('archive/')
  end

  it 'registers only the canonical suite and retires every matrix-only path' do
    registry = File.read(File.join(REPO_ROOT, 'tests/all-tests.nix'))
    expect(registry.scan('"osctl/nfs-cancellation"').length).to eq(1)
    %w[baseline native110 native116].each do |suffix|
      expect(registry).not_to include("osctl/nfs-cancellation-#{suffix}")
      expect(File).not_to exist(
        File.join(REPO_ROOT, "tests/suite/osctl/nfs-cancellation-#{suffix}.nix")
      )
    end
    expect(File).not_to exist(
      File.join(
        REPO_ROOT,
        "tests/configs/vpsadminos/nfs-cancellation-#{stable_metadata.fetch('release')}.nix"
      )
    )
    expect(File).not_to exist(
      File.join(REPO_ROOT, 'tests/configs/vpsadminos/nfs-cancellation-6.12.116.nix')
    )
  end

  it 'keeps the stable active 66-example surface and protocol order' do
    common = [
      'drains an admitted shutdown writer before final unmount',
      'cancels shared mounts on forced stop without cancelling another container',
      'cancels a mount already blocked inside the kernel',
      'bounds graceful shutdown with forced fallback during an outage',
      "cancels a remote lock waiter without releasing another container's lock",
      'cancels an NFS mount in a processless child network namespace',
      'rejects new mounts and descendants after host terminal cancellation',
      'recaptures cancellation handles after osctld restarts',
      'finishes unexpected init exit while NFS is unreachable',
      'finishes PID1 exit with its own dirty NFS file descriptor',
      'host cancellation controls are root-only with exact modes',
      'drains every superblock of a shared client in one terminal action',
      'rejects or safely joins a mount racing terminal cancellation',
      'repeated terminal cancellation is idempotent',
      'container restart creates fresh NFS client state and a working mount',
      'survives 25 forced stop/restart cycles with terminal cancellation'
    ]
    version_three = common.dup.insert(
      1,
      'releases a server after post-publication RPC auth setup fails',
      'shuts down a legacy server before the first NLM lock'
    )
    expect(collect_example_messages(teardown_script)).to eq(
      version_three + common + common + common
    )
  end

  it 'constructs a fail-fast, diagnostic post-publication NFSv3 failure check' do
    partial_init = teardown_script
                   .split('it "releases a server after post-publication RPC auth setup fails" do', 2)
                   .fetch(1)
                   .split('it "shuts down a legacy server before the first NLM lock" do', 2)
                   .fetch(0)
    blocked_auth = teardown_script
                   .split('def failed_nfs_mount_result_command', 2)
                   .fetch(1)
                   .split('def start_writer', 2)
                   .fetch(0)

    expect(teardown_script).to include(
      %("kernelSourceRevision":"#{stable_metadata.fetch('revision')}")
    )
    expect(partial_init).to include(
      'vers=3,proto=tcp,timeo=300,retrans=2,sec=krb5,nolock,retry=0'
    )
    expect(partial_init.scan('nolock,retry=0').length).to eq(1)
    expect(partial_init).not_to include('mountvers=')
    expect(teardown_script).to include('--options fsid=1235,rw,no_root_squash,')
    expect(teardown_script.scan('sec=sys:krb5 server1').length).to eq(1)
    expect(teardown_script).not_to include('sec=none server1')
    expect(partial_init.gsub('\\"', '"')).to include(
      'i=0; while test "$i" -lt 300'
    )
    expect(partial_init).to include(
      'osctl ct exec nfs1 test -s /root/nfs-failed-mount-status'
    )
    expect(partial_init).to include(
      'NFS auth trigger exited before module request with status'
    )
    expect(partial_init).to include(
      'supervisor = failed_nfs_mount_supervisor_command(mount_command: mount_command)'
    )
    expect(partial_init).to include(
      '/sbin/mount.nfs 10.0.0.10:/srv/nfs-cancellation-auth-null'
    )
    expect(partial_init).to include(
      'echo $! > /root/nfs-failed-mount-supervisor.pid'
    )
    expect(partial_init).to include('/root/nfs-failed-mount-supervisor.pid')
    expect(partial_init).to include('rpc-auth-gss-390003')
    expect(partial_init).to include(
      'test ! -e /run/nfs-failed-modprobe-rejected'
    )
    expect(partial_init).to include(
      'wc -l < /run/nfs-failed-modprobe-invocations'
    )
    expect(partial_init.index('test -s /run/nfs-failed-modprobe-request'))
      .to be < partial_init.index('osctl ct exec nfs1 test -s /root/nfs-failed-mount-status')
    expect(partial_init.index("if trigger == 'status'"))
      .to be < partial_init.index('new_servers = transient_nfs_server_ids')
    expect(partial_init).to include('expect(new_servers.length).to eq(1)')
    expect(partial_init).to include("server=/sys/fs/nfs/\#{server_id}")
    expect(partial_init).to include(
      '/run/nfs-shutdown-unmount --expect-eagain \"$server/shutdown\"'
    )
    expect(partial_init).to include('partial_callback=eagain')
    expect(partial_init).not_to include('shutdown_write=1')
    expect(partial_init).not_to include('> /sys/fs/nfs/net/nfs_client/')
    expect(partial_init).to include("test ! -e /sys/fs/nfs/\#{server_id}")
    expect(partial_init).to include('post-publication-failure-survived')
    expect(partial_init).to include(
      '/BUG:|Oops:|KASAN|refcount_t:|list_del corruption|hung task/i'
    )

    callback = partial_init.split('callback_body =', 2).fetch(1)
                           .split("machine.succeeds('touch /run/nfs-failed-modprobe-release')", 2)
                           .fetch(0)
                           .gsub('\\"', '"')
    pre_read = callback.index('cat "$server/shutdown")')
    helper = callback.index('--expect-eagain "$server/shutdown"')
    marker = callback.index('test "$result" = partial_callback=eagain')
    post_read = callback.index('cat "$server/shutdown")', pre_read + 1)
    net_shutdown = callback.index('nfs_client/shutdown)" = 0')
    tree_shutdown = callback.index('nfs_client/shutdown_tree)" = 0')
    expect([pre_read, helper, marker, post_read, net_shutdown, tree_shutdown])
      .to all(be_a(Integer))
    expect(pre_read).to be < helper
    expect(helper).to be < marker
    expect(marker).to be < post_read
    expect(post_read).to be < net_shutdown
    expect(net_shutdown).to be < tree_shutdown

    request_check = partial_init.index("expect(request).to eq('rpc-auth-gss-390003')")
    server_selection = partial_init.index('server_id = new_servers.fetch(0)')
    callback_start = partial_init.index('callback_body =')
    helper_release = partial_init.index(
      "machine.succeeds('touch /run/nfs-failed-modprobe-release')"
    )
    expect([request_check, server_selection, callback_start, helper_release])
      .to all(be_a(Integer))
    expect(request_check).to be < server_selection
    expect(server_selection).to be < callback_start
    expect(callback_start).to be < helper_release

    expect(evaluate_fixture_script).to include('--expect-eagain')

    %w[cmdline status wchan syscall stack].each do |proc_entry|
      expect(blocked_auth).to include("$proc/#{proc_entry}")
    end
    expect(blocked_auth).to include("proc=/proc/\#{init_pid}/root/proc/$pid")
    expect(blocked_auth).to include('NFS_TRANSIENT_SERVER=%f')
    expect(blocked_auth).to include('cat /proc/sys/kernel/modprobe')
    expect(blocked_auth).to include("stat -Lc 'NFS_WRAPPER")
    expect(blocked_auth).to include('NFS_WRAPPER_READABLE=yes')
    expect(blocked_auth).to include('NFS_WRAPPER_READABLE=no')
    expect(blocked_auth).to include('NFS_MODPROBE_MARKER_$marker')
    expect(blocked_auth).to include('NFS_FAILED_MOUNT_STATUS=')
    expect(blocked_auth).to include('NFS_FAILED_MOUNT_LOG_BEGIN')
    expect(blocked_auth).to include('mount_pid=$!')
    expect(blocked_auth).to include('wait \"$mount_pid\"')
    expect(blocked_auth).to include("grep -Eq '(^|/)mount[.]nfs$'")
    expect(blocked_auth).to include('10.0.0.10:/srv/nfs-cancellation-auth-null')
    expect(blocked_auth).to include('/mnt/nfs-failed')
    expect(blocked_auth).to include("grep -Eq '(^|,)vers=3(,|$)'")
    expect(blocked_auth).to include("grep -Eq '(^|,)mountvers='")
    expect(blocked_auth).to include('sec=krb5,nolock,retry=0')
    expect(blocked_auth).to include("grep -q '^auth_rpcgss ' /proc/modules")
    expect(blocked_auth).to include("grep -q '^rpcsec_gss_krb5 ' /proc/modules")
    expect(blocked_auth).to include('/unused-kmod/bin/rmmod rpcsec_gss_krb5')
    expect(blocked_auth).to include(
      'sysctl -qw kernel.modprobe=/unused-nfs-blocked-modprobe'
    )
    expect(blocked_auth).to include('/unused-kmod/bin/modprobe rpcsec_gss_krb5')
    auth_precondition = blocked_auth.index("grep -q '^auth_rpcgss ' /proc/modules")
    helper_precondition = blocked_auth.index(
      'test -x /unused-nfs-blocked-modprobe', auth_precondition
    )
    module_removal = blocked_auth.index('/unused-kmod/bin/rmmod rpcsec_gss_krb5')
    helper_install = blocked_auth.index(
      'sysctl -qw kernel.modprobe=/unused-nfs-blocked-modprobe'
    )
    expect(auth_precondition).to be < helper_precondition
    expect(helper_precondition).to be < module_removal
    expect(module_removal).to be < helper_install
    expect(blocked_auth.index("'release module request'"))
      .to be < blocked_auth.index("'stop unfinished mount'")
    expect(blocked_auth.index("'stop unfinished mount'"))
      .to be < blocked_auth.index("'wait for mount supervisor'")
    expect(blocked_auth.index("'wait for mount supervisor'"))
      .to be < blocked_auth.index("'emit failed mount result'")
    expect(blocked_auth.index("'emit failed mount result'"))
      .to be < blocked_auth.index("'unmount failed target'")
    expect(blocked_auth.index("'unmount failed target'"))
      .to be < blocked_auth.index("'restore kernel.modprobe'")
    expect(blocked_auth.index("'restore kernel.modprobe'"))
      .to be < blocked_auth.index("'restore KRB5 mechanism module'")
    expect(blocked_auth.index("'restore KRB5 mechanism module'"))
      .to be < blocked_auth.index("'remove host failure controls'")
    expect(blocked_auth.index("'remove host failure controls'"))
      .to be < blocked_auth.index("'remove container failure controls'")
  end

  it 'renders and executes the exact marker-first KRB5 module helper' do
    helper = evaluate_blocked_modprobe_script
    common_source = File.read(
      File.join(REPO_ROOT, 'tests/suite/osctl/nfs-cancellation-common.nix')
    )
    expect(common_source).to include(
      'blockedNfsAuthModprobe = pkgs.writeShellScript "nfs-blocked-modprobe"'
    )
    expect(helper).to match(%r{/nix/store/[^/]+/bin/sleep 0[.]1})
    expect(helper).not_to include('exec "$original"')

    helper_pid = nil
    Dir.mktmpdir('nfs-modprobe-helper') do |dir|
      prefix = File.join(dir, 'nfs-failed-modprobe-')
      script = helper.gsub('/run/nfs-failed-modprobe-', prefix)
      invocations = "#{prefix}invocations"
      request = "#{prefix}request"
      release = "#{prefix}release"
      rejected = "#{prefix}rejected"
      pid_path = "#{prefix}helper.pid"

      _, _, status = Open3.capture3(
        'sh', '-c', script, 'nfs-blocked-modprobe', '-q', '--', 'unrelated-module'
      )
      expect(status).not_to be_success
      expect(File.readlines(invocations, chomp: true)).to eq(
        ['-q -- unrelated-module']
      )
      expect(File).not_to exist(request)
      expect(File.read(rejected).strip).to eq('-q -- unrelated-module')
      File.delete(invocations, rejected)

      helper_pid = Process.spawn(
        'sh', '-c', script, 'nfs-blocked-modprobe',
        '-q', '--', 'rpc-auth-gss-390003'
      )
      Timeout.timeout(5) do
        sleep(0.01) until File.exist?(request) && File.exist?(pid_path)
      end
      expect(File.read(request).strip).to eq('rpc-auth-gss-390003')
      expect(Integer(File.read(pid_path).strip)).to eq(helper_pid)
      expect(File.readlines(invocations, chomp: true)).to eq(
        ['-q -- rpc-auth-gss-390003']
      )
      expect(File).not_to exist(rejected)
      expect { Process.kill(0, helper_pid) }.not_to raise_error

      File.write(release, '')
      _, status = Process.wait2(helper_pid)
      finished_pid = helper_pid
      helper_pid = nil
      expect(status).not_to be_success
      expect { Process.kill(0, finished_pid) }.to raise_error(Errno::ESRCH)
    ensure
      if helper_pid
        Process.kill('KILL', helper_pid)
        Process.wait(helper_pid)
      end
    end
  end

  it 'invokes the KRB5 hold only from the stable partial-init example' do
    script = evaluate_fixture_script
    expect(script.scan('with_blocked_nfs_auth_module do').length).to eq(1)
    expect(script).to include('--options fsid=1235,rw,no_root_squash,')
    expect(script.scan('sec=sys:krb5 server1').length).to eq(1)
    expect(script).not_to include('sec=none server1')
  end

  it 'records, authenticates and stops the actual mount child without an orphan' do
    harness = teardown_harness_class.new
    child_pid = nil
    supervisor_pid = nil

    Dir.mktmpdir('nfs-mount-supervisor') do |dir|
      mount_path = File.join(dir, 'mount.nfs')
      observed_pid_path = File.join(dir, 'observed.pid')
      pid_path = File.join(dir, 'mount.pid')
      supervisor_pid_path = File.join(dir, 'supervisor.pid')
      status_path = File.join(dir, 'mount.status')
      log_path = File.join(dir, 'mount.log')
      File.write(
        mount_path,
        <<~SH
          #!/bin/sh
          printf '%s\n' "$$" > "$NFS_TEST_OBSERVED_PID"
          echo fake-mount-started
          trap 'exit 23' TERM
          while :; do :; done
        SH
      )
      File.chmod(0o755, mount_path)

      options = 'vers=3,proto=tcp,timeo=300,retrans=2,sec=krb5,nolock,retry=0'
      mount_command =
        "NFS_TEST_OBSERVED_PID=#{Shellwords.escape(observed_pid_path)} " \
        "#{Shellwords.escape(mount_path)} -t nfs -o #{Shellwords.escape(options)} " \
        '10.0.0.10:/srv/nfs-cancellation-auth-null /mnt/nfs-failed'
      supervisor = harness.failed_nfs_mount_supervisor_command(
        mount_command: mount_command,
        pid_path: pid_path,
        status_path: status_path,
        log_path: log_path
      )
      supervisor_pid = Process.spawn('sh', '-c', supervisor)
      File.write(supervisor_pid_path, "#{supervisor_pid}\n")
      Timeout.timeout(5) do
        sleep(0.01) until File.exist?(pid_path) && File.exist?(observed_pid_path)
      end
      child_pid = Integer(File.read(pid_path).strip)
      observed_pid = Integer(File.read(observed_pid_path).strip)
      expect(child_pid).to eq(observed_pid)
      expect(child_pid).not_to eq(supervisor_pid)

      stop_body = harness.failed_nfs_mount_stop_body(
        pid_path: pid_path,
        status_path: status_path
      )
      File.write(pid_path, "#{supervisor_pid}\n")
      expect(system('sh', '-c', stop_body)).to be(false)
      expect { Process.kill(0, supervisor_pid) }.not_to raise_error
      expect { Process.kill(0, child_pid) }.not_to raise_error

      File.write(pid_path, "#{child_pid}\n")
      expect(system('sh', '-c', stop_body)).to be(true)
      finished_supervisor_pid = supervisor_pid
      Timeout.timeout(5) { Process.wait(supervisor_pid) }
      supervisor_pid = nil
      expect(File.read(status_path).strip).to eq('23')
      expect(File.read(log_path)).to include('fake-mount-started')
      done_body = harness.failed_nfs_mount_supervisor_done_body(
        supervisor_pid_path: supervisor_pid_path,
        status_path: status_path
      )
      expect(system('sh', '-c', done_body)).to be(true)
      expect(finished_supervisor_pid).not_to eq(child_pid)
      expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
      child_pid = nil
    ensure
      [child_pid, supervisor_pid].compact.each do |pid|
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(supervisor_pid) if supervisor_pid
      rescue Errno::ECHILD
        nil
      end
    end
  end

  it 'fails live final liveness checks without deleting their evidence' do
    harness = teardown_harness_class.new

    Dir.mktmpdir('nfs-final-liveness') do |dir|
      host_paths = %w[request release invocations rejected helper.pid]
                   .map { |name| File.join(dir, "host-#{name}") }
      helper_pid_path = host_paths.last
      ['', "not-a-pid\n"].each do |malformed_pid|
        host_paths.each { |path| File.write(path, "evidence\n") }
        File.write(helper_pid_path, malformed_pid)
        host_body = harness.failed_nfs_host_cleanup_body(
          helper_pid_path: helper_pid_path,
          control_paths: host_paths
        )
        expect(system('sh', '-c', host_body)).to be(false)
        expect(host_paths).to all(satisfy { |path| File.exist?(path) })
      end

      host_paths.each { |path| File.write(path, "evidence\n") }
      File.write(helper_pid_path, "#{Process.pid}\n")
      host_body = harness.failed_nfs_host_cleanup_body(
        helper_pid_path: helper_pid_path,
        control_paths: host_paths
      )
      expect(system('sh', '-c', host_body)).to be(false)
      expect(host_paths).to all(satisfy { |path| File.exist?(path) })

      dead_pid = Process.spawn('sh', '-c', 'exit 0')
      Process.wait(dead_pid)
      File.write(helper_pid_path, "#{dead_pid}\n")
      expect(system('sh', '-c', host_body)).to be(true)
      expect(host_paths).to all(satisfy { |path| !File.exist?(path) })

      child_pid_path = File.join(dir, 'mount.pid')
      supervisor_pid_path = File.join(dir, 'supervisor.pid')
      status_path = File.join(dir, 'mount.status')
      log_path = File.join(dir, 'mount.log')
      evidence_paths = [child_pid_path, supervisor_pid_path, status_path, log_path]
      mountpoint = File.join(dir, 'mountpoint')
      container_body = harness.failed_nfs_container_cleanup_body(
        pid_paths: [child_pid_path, supervisor_pid_path],
        evidence_paths: evidence_paths,
        mountpoint: mountpoint
      )

      [child_pid_path, supervisor_pid_path].each do |malformed_path|
        ['', "not-a-pid\n"].each do |malformed_pid|
          FileUtils.mkdir_p(mountpoint)
          evidence_paths.each { |path| File.write(path, "evidence\n") }
          File.write(child_pid_path, "#{dead_pid}\n")
          File.write(supervisor_pid_path, "#{dead_pid}\n")
          File.write(malformed_path, malformed_pid)
          expect(system('sh', '-c', container_body)).to be(false)
          expect(evidence_paths).to all(satisfy { |path| File.exist?(path) })
          expect(Dir).to exist(mountpoint)
        end
      end

      [child_pid_path, supervisor_pid_path].each do |live_path|
        FileUtils.mkdir_p(mountpoint)
        evidence_paths.each { |path| File.write(path, "evidence\n") }
        File.write(child_pid_path, "#{dead_pid}\n")
        File.write(supervisor_pid_path, "#{dead_pid}\n")
        File.write(live_path, "#{Process.pid}\n")
        expect(system('sh', '-c', container_body)).to be(false)
        expect(evidence_paths).to all(satisfy { |path| File.exist?(path) })
        expect(Dir).to exist(mountpoint)
      end

      File.write(child_pid_path, "#{dead_pid}\n")
      File.write(supervisor_pid_path, "#{dead_pid}\n")
      expect(system('sh', '-c', container_body)).to be(true)
      expect(evidence_paths).to all(satisfy { |path| !File.exist?(path) })
      expect(Dir).not_to exist(mountpoint)

      File.write(status_path, "23\n")
      File.write(supervisor_pid_path, "#{Process.pid}\n")
      supervisor_body = harness.failed_nfs_mount_supervisor_done_body(
        supervisor_pid_path: supervisor_pid_path,
        status_path: status_path
      )
      expect(system('sh', '-c', supervisor_body)).to be(false)
      expect(File).to exist(status_path)
      expect(File).to exist(supervisor_pid_path)
      File.write(supervisor_pid_path, "#{dead_pid}\n")
      expect(system('sh', '-c', supervisor_body)).to be(true)
    end
  end

  it 'refuses children without NFSv3 or with a mount protocol override' do
    harness = teardown_harness_class.new
    invalid_options = [
      'proto=tcp,timeo=300,retrans=2,sec=krb5,nolock,retry=0',
      'vers=3,mountvers=1,proto=tcp,timeo=300,retrans=2,sec=krb5,nolock,retry=0'
    ]

    invalid_options.each do |options|
      child_pid = nil
      supervisor_pid = nil

      Dir.mktmpdir('nfs-mount-version-auth') do |dir|
        mount_path = File.join(dir, 'mount.nfs')
        observed_pid_path = File.join(dir, 'observed.pid')
        pid_path = File.join(dir, 'mount.pid')
        status_path = File.join(dir, 'mount.status')
        log_path = File.join(dir, 'mount.log')
        File.write(
          mount_path,
          <<~SH
            #!/bin/sh
            printf '%s\n' "$$" > "$NFS_TEST_OBSERVED_PID"
            echo fake-mount-started
            trap 'exit 23' TERM
            while :; do :; done
          SH
        )
        File.chmod(0o755, mount_path)

        mount_command =
          "NFS_TEST_OBSERVED_PID=#{Shellwords.escape(observed_pid_path)} " \
          "#{Shellwords.escape(mount_path)} -t nfs -o #{Shellwords.escape(options)} " \
          '10.0.0.10:/srv/nfs-cancellation-auth-null /mnt/nfs-failed'
        supervisor = harness.failed_nfs_mount_supervisor_command(
          mount_command: mount_command,
          pid_path: pid_path,
          status_path: status_path,
          log_path: log_path
        )
        supervisor_pid = Process.spawn('sh', '-c', supervisor)
        Timeout.timeout(5) do
          sleep(0.01) until File.exist?(pid_path) && File.exist?(observed_pid_path)
        end
        child_pid = Integer(File.read(pid_path).strip)
        expect(child_pid).to eq(Integer(File.read(observed_pid_path).strip))

        stop_body = harness.failed_nfs_mount_stop_body(
          pid_path: pid_path,
          status_path: status_path
        )
        expect(system('sh', '-c', stop_body)).to be(false)
        expect { Process.kill(0, child_pid) }.not_to raise_error

        Process.kill('TERM', child_pid)
        finished_child_pid = child_pid
        Timeout.timeout(5) { Process.wait(supervisor_pid) }
        supervisor_pid = nil
        child_pid = nil
        expect(File.read(status_path).strip).to eq('23')
        expect { Process.kill(0, finished_child_pid) }.to raise_error(Errno::ESRCH)
      ensure
        [child_pid, supervisor_pid].compact.each do |pid|
          Process.kill('KILL', pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait(supervisor_pid) if supervisor_pid
        rescue Errno::ECHILD
          nil
        end
      end
    end
  end

  it 'keeps an auth-trigger failure primary while attempting every cleanup step' do
    harness = teardown_harness_class.new
    machine = instance_double(OsVm::Machine)
    primary_error = RuntimeError.new('auth trigger failed')
    evidence_error = RuntimeError.new('evidence output failed')
    restore_error = RuntimeError.new('KRB5 module restore failed')
    host_cleanup_error = RuntimeError.new('host cleanup failed')
    commands = []
    warnings = []
    host_cleanup = harness.failed_nfs_host_cleanup_body

    allow(machine).to receive(:succeeds) do |command, **|
      commands << command
      if command == 'cat /proc/sys/kernel/modprobe'
        [0, "/sbin/modprobe\n"]
      elsif command.include?('/unused-kmod/bin/modprobe rpcsec_gss_krb5')
        raise restore_error
      elsif command == host_cleanup
        raise host_cleanup_error
      else
        [0, '']
      end
    end
    allow(machine).to receive(:all_succeed) do |*all_commands|
      commands.concat(all_commands)
      [0, '']
    end
    allow(machine).to receive(:execute) do |command, **|
      commands << command
      raise evidence_error
    end
    allow(machine).to receive(:wait_until_succeeds) do |command, **|
      commands << command
      [0, '']
    end
    harness.define_singleton_method(:machine) { machine }
    harness.define_singleton_method(:warn) { |message| warnings << message }

    expect do
      harness.with_blocked_nfs_auth_module { raise primary_error }
    end.to raise_error(primary_error)
    expect(warnings).to include(
      a_string_including('emit failed mount result cleanup failed')
    )
    expect(warnings).to include(
      a_string_including('restore KRB5 mechanism module cleanup failed')
    )
    expect(warnings).to include(
      a_string_including('remove host failure controls cleanup failed')
    )
    expect(commands.index { |command| command == 'touch /run/nfs-failed-modprobe-release' })
      .to be < commands.index { |command| command.include?('NFS_FAILED_MOUNT_STATUS') }
    expect(commands).to include(a_string_including('sysctl -qw kernel.modprobe=/sbin/modprobe'))
    expect(commands).to include(a_string_including('/unused-kmod/bin/rmmod rpcsec_gss_krb5'))
    expect(commands).to include(a_string_including('/unused-kmod/bin/modprobe rpcsec_gss_krb5'))
    expect(commands).to include(a_string_including('nfs-failed-mount-supervisor.pid'))
    expect(commands).to include(a_string_including('mountpoint -q /mnt/nfs-failed'))
    expect(commands).to include(a_string_including('nfs-failed-mount-status'))
    host_cleanup_index = commands.index(host_cleanup)
    container_cleanup_index = commands.index do |command|
      command.include?('osctl ct exec nfs1 sh -ec')
    end
    expect(host_cleanup_index).to be < container_cleanup_index
  end

  it 'surfaces a KRB5 module restore failure after a successful auth body' do
    harness = teardown_harness_class.new
    machine = instance_double(OsVm::Machine)
    restore_error = RuntimeError.new('KRB5 module restore failed')
    commands = []
    warnings = []

    allow(machine).to receive(:succeeds) do |command, **|
      commands << command
      if command == 'cat /proc/sys/kernel/modprobe'
        [0, "/sbin/modprobe\n"]
      elsif command.include?('/unused-kmod/bin/modprobe rpcsec_gss_krb5')
        raise restore_error
      else
        [0, '']
      end
    end
    allow(machine).to receive(:all_succeed) do |*all_commands|
      commands.concat(all_commands)
      [0, '']
    end
    allow(machine).to receive(:execute) do |command, **|
      commands << command
      [0, '']
    end
    allow(machine).to receive(:wait_until_succeeds) do |command, **|
      commands << command
      [0, '']
    end
    harness.define_singleton_method(:machine) { machine }
    harness.define_singleton_method(:warn) { |message| warnings << message }

    expect { harness.with_blocked_nfs_auth_module { :complete } }
      .to raise_error(restore_error)
    expect(warnings).to contain_exactly(
      a_string_including('restore KRB5 mechanism module cleanup failed')
    )
    restore = commands.index do |command|
      command.include?('/unused-kmod/bin/modprobe rpcsec_gss_krb5')
    end
    remove = commands.index do |command|
      command.include?('helper=$(cat /run/nfs-failed-modprobe-helper.pid)')
    end
    expect(restore).to be < remove
  end

  it 'fails before the auth body when KRB5 module removal is unsuccessful' do
    harness = teardown_harness_class.new
    machine = instance_double(OsVm::Machine)
    removal_error = RuntimeError.new('KRB5 module is busy')
    body_called = false

    allow(machine).to receive(:succeeds) do |command, **|
      if command == 'cat /proc/sys/kernel/modprobe'
        [0, "/sbin/modprobe\n"]
      elsif command.include?('/unused-kmod/bin/rmmod rpcsec_gss_krb5')
        raise removal_error
      else
        [0, '']
      end
    end
    allow(machine).to receive_messages(
      all_succeed: [0, ''],
      execute: [0, ''],
      wait_until_succeeds: [0, '']
    )
    harness.define_singleton_method(:machine) { machine }
    harness.define_singleton_method(:warn) { |_| nil }

    expect do
      harness.with_blocked_nfs_auth_module { body_called = true }
    end.to raise_error(removal_error)
    expect(body_called).to be(false)
  end

  it 'keeps the stable forced-soft policy separate from cancellation coverage' do
    expect(common_source).to include('nfsRetryOptions = "timeo=300,retrans=2";')
    expect(teardown_script).to include("expect(options).to include('soft')")
    expect(teardown_script).to include("expect(options).not_to include('hard', 'softerr')")
    expect(teardown_script).to include("vers=\#{version},proto=tcp,timeo=300,retrans=2")
    expect(teardown_script).not_to include('retries an outage beyond soft timeout')
    expect(teardown_script).to include('cancels shared mounts on forced stop')
  end

  it 'keeps a teardown body failure primary while attempting every restore step' do
    harness = teardown_harness_class.new
    machine = instance_double(OsVm::Machine)
    primary_error = RuntimeError.new('teardown body failed')
    stop_error = RuntimeError.new('stop failed')
    start_error = RuntimeError.new('start failed')
    remount_error = RuntimeError.new('remount failed')
    operations = []
    warnings = []

    allow(machine).to receive(:succeeds) do |command, **|
      operations << :state
      if command.include?('ct show')
        [0, "running\n"]
      else
        operations[-1] = :start
        raise start_error
      end
    end
    harness.define_singleton_method(:machine) { machine }
    harness.define_singleton_method(:stop_nfs_client) do
      operations << :stop
      raise stop_error
    end
    harness.define_singleton_method(:mount_nfs) do |*|
      operations << :remount
      raise remount_error
    end
    harness.define_singleton_method(:warn) { |message| warnings << message }

    expect do
      harness.with_restored_nfs_client('3') { raise primary_error }
    end.to raise_error(primary_error)
    expect(operations).to eq(%i[state stop start remount])
    expect(warnings.length).to eq(3)
    %w[stop start remount].each do |operation|
      expect(warnings).to include(a_string_including("#{operation} cleanup failed"))
    end
  end

  it 'attempts processless cleanup before restoration without replacing the primary failure' do
    harness = teardown_harness_class.new
    machine = instance_double(OsVm::Machine)
    primary_error = RuntimeError.new('processless body failed')
    cleanup_error = RuntimeError.new('namespace cleanup failed')
    operations = []
    warnings = []

    allow(machine).to receive(:succeeds) do |command, **|
      operations << (command.include?('ct show') ? :state : :start)
      [0, command.include?('ct show') ? "running\n" : '']
    end
    harness.define_singleton_method(:machine) { machine }
    harness.define_singleton_method(:stop_nfs_client) { operations << :stop }
    harness.define_singleton_method(:mount_nfs) { |*| operations << :remount }
    harness.define_singleton_method(:warn) { |message| warnings << message }

    cleanup = lambda do
      operations << :namespace_cleanup
      raise cleanup_error
    end
    expect do
      harness.with_restored_nfs_client(
        '4.1',
        before_restore: [['release child network namespace', cleanup]]
      ) { raise primary_error }
    end.to raise_error(primary_error)
    expect(operations).to eq(%i[namespace_cleanup state stop start remount])
    expect(warnings).to contain_exactly(
      a_string_including('release child network namespace cleanup failed')
    )
  end

  it 'keeps a teardown body failure primary when every restore step succeeds' do
    harness = teardown_harness_class.new
    machine = instance_double(OsVm::Machine)
    primary_error = RuntimeError.new('teardown body failed')
    operations = []
    warnings = []

    allow(machine).to receive(:succeeds) do |command, **|
      operations << (command.include?('ct show') ? :state : :start)
      [0, command.include?('ct show') ? "running\n" : '']
    end
    harness.define_singleton_method(:machine) { machine }
    harness.define_singleton_method(:stop_nfs_client) { operations << :stop }
    harness.define_singleton_method(:mount_nfs) { |*| operations << :remount }
    harness.define_singleton_method(:warn) { |message| warnings << message }

    expect do
      harness.with_restored_nfs_client('4.0') { raise primary_error }
    end.to raise_error(primary_error)
    expect(operations).to eq(%i[state stop start remount])
    expect(warnings).to be_empty
  end

  it 'surfaces the first restore failure after a successful teardown body' do
    harness = teardown_harness_class.new
    machine = instance_double(OsVm::Machine)
    stop_error = RuntimeError.new('stop failed')
    operations = []
    warnings = []

    allow(machine).to receive(:succeeds) do |command, **|
      operations << (command.include?('ct show') ? :state : :start)
      [0, command.include?('ct show') ? "running\n" : '']
    end
    harness.define_singleton_method(:machine) { machine }
    harness.define_singleton_method(:stop_nfs_client) do
      operations << :stop
      raise stop_error
    end
    harness.define_singleton_method(:mount_nfs) { |*| operations << :remount }
    harness.define_singleton_method(:warn) { |message| warnings << message }

    expect do
      harness.with_restored_nfs_client('4.2') { operations << :body }
    end.to raise_error(stop_error)
    expect(operations).to eq(%i[body state stop start remount])
    expect(warnings.length).to eq(1)
    expect(warnings.first).to include('stop cleanup failed')
  end

  it 'completes normally when the teardown body and every restore step succeed' do
    harness = teardown_harness_class.new
    machine = instance_double(OsVm::Machine)
    operations = []
    warnings = []

    allow(machine).to receive(:succeeds) do |command, **|
      operations << (command.include?('ct show') ? :state : :start)
      [0, command.include?('ct show') ? "running\n" : '']
    end
    harness.define_singleton_method(:machine) { machine }
    harness.define_singleton_method(:stop_nfs_client) { operations << :stop }
    harness.define_singleton_method(:mount_nfs) { |*| operations << :remount }
    harness.define_singleton_method(:warn) { |message| warnings << message }

    expect do
      harness.with_restored_nfs_client('4.1') { operations << :body }
    end.not_to raise_error
    expect(operations).to eq(%i[body state stop start remount])
    expect(warnings).to be_empty
  end
end
