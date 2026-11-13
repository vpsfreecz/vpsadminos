require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../../rtnl-monitor/root_manifest'

class RootManifestTest < Minitest::Test
  Manifest = OsCtl::RtnlMonitor::RootManifest

  def setup
    @tmp = Dir.mktmpdir('rtnl-roots-')
    @mount = File.join(@tmp, 'cgroup')
    @proc = File.join(@tmp, 'proc')
    @mountinfo = File.join(@tmp, 'mountinfo')
    FileUtils.mkdir_p([@mount, @proc])
    File.write(@mountinfo, "12 1 0:30 / #{@mount} rw - cgroup2 cgroup rw\n")
    @path = 'osctl/pool.pool/group.default/user.alice/ct.one'
    @ct = { pool: 'pool', id: 'one', user: 'alice', state: 'running', init_pid: 123,
            group_path: "#{@path}/user-owned" }
    FileUtils.mkdir_p(File.join(@mount, @path))
    write_init
    @reader = Manifest.new(cgroup_mount: @mount, proc_root: @proc, mountinfo: @mountinfo)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def write_init(pid: 123, start: 99, state: 'S', membership: "#{@path}/user-owned/lxc.payload.one")
    dir = File.join(@proc, pid.to_s)
    FileUtils.mkdir_p(dir)
    fields = Array.new(20, '0')
    fields[0] = state
    fields[19] = start.to_s
    File.write(File.join(dir, 'stat'), "#{pid} (init with ) name) #{fields.join(' ')}\n")
    File.write(File.join(dir, 'cgroup'), "0::/#{membership}\n")
  end

  def build(rows = [@ct], now: 10)
    @reader.build(rows, generated_monotonic_ns: now)
  end

  def test_manifest_uses_container_base_and_stable_run_token
    before = build
    after = build(now: 20)
    assert_equal(1, before[:schema])
    assert_equal(@path, before[:roots][0][:path])
    assert_equal(before[:roots][0][:run_token], after[:roots][0][:run_token])
    assert_equal(20, after[:generated_monotonic_ns])
    assert_equal(64, after[:roots][0][:run_token].length)
  end

  def test_new_init_run_changes_token_even_if_pid_is_reused
    old = build[:roots][0][:run_token]
    write_init(start: 100)
    refute_equal(old, build[:roots][0][:run_token])
  end

  def test_init_migration_within_same_root_preserves_run_token
    old = build[:roots][0][:run_token]
    write_init(membership: "#{@path}/user-owned/nested/init")
    assert_equal(old, build[:roots][0][:run_token])
  end

  def test_root_replacement_changes_run_token
    old = build[:roots][0][:run_token]
    FileUtils.mv(File.join(@mount, @path), File.join(@mount, "#{@path}.old"))
    FileUtils.mkdir_p(File.join(@mount, @path))
    refute_equal(old, build[:roots][0][:run_token])
  end

  def test_stop_or_disappearing_init_does_not_publish_fresh_empty_inventory
    assert_raises(Manifest::InvalidInventory) { build([@ct.merge(state: 'stopped')]) }
    File.unlink(File.join(@proc, '123', 'stat'))
    assert_raises(Manifest::InvalidInventory) { build }
  end

  def test_exited_or_moved_init_is_not_attributed
    write_init(state: 'Z')
    assert_raises(Manifest::InvalidInventory) { build }
    write_init(membership: 'osctl/another-root/payload')
    assert_raises(Manifest::InvalidInventory) { build }
  end

  def test_wrong_leaf_and_path_escape_are_rejected
    assert_raises(Manifest::InvalidInventory) { build([@ct.merge(group_path: "#{@path}/wrapper")]) }
    assert_raises(Manifest::InvalidInventory) { build([@ct.merge(group_path: "../#{@ct[:group_path]}")]) }
    assert_raises(Manifest::InvalidInventory) { build([@ct.merge(user: 'bob')]) }
  end

  def test_duplicate_roots_and_capacity_exhaustion_are_invalid
    assert_raises(Manifest::InvalidInventory) { build([@ct, @ct]) }
    @reader = Manifest.new(cgroup_mount: @mount, max_roots: 0, proc_root: @proc, mountinfo: @mountinfo)
    assert_raises(Manifest::InvalidInventory) { build }
  end

  def test_overlapping_root_is_rejected_even_with_intervening_sorted_sibling
    nested = "#{@path}/child/user.bob/ct.two"
    sibling = @path.sub('ct.one', 'ct.one-0')
    FileUtils.mkdir_p([File.join(@mount, nested), File.join(@mount, sibling)])
    write_init(pid: 124, membership: "#{nested}/user-owned/payload")
    write_init(pid: 125, membership: "#{sibling}/user-owned/payload")
    rows = [@ct,
            @ct.merge(id: 'two', user: 'bob', init_pid: 124, group_path: "#{nested}/user-owned"),
            @ct.merge(id: 'one-0', init_pid: 125, group_path: "#{sibling}/user-owned")]
    assert_raises(Manifest::InvalidInventory) { build(rows) }
  end

  def test_identity_change_between_proc_reads_invalidates_whole_refresh
    calls = 0
    @reader.define_singleton_method(:init_identity) do |*_args|
      calls += 1
      [calls, 'payload']
    end
    assert_raises(Manifest::InvalidInventory) { build }
    assert_equal(2, calls)
  end

  def test_non_root_or_wrong_filesystem_mount_is_rejected
    File.write(@mountinfo, "12 1 0:30 /delegated #{@mount} rw - cgroup2 cgroup rw\n")
    assert_raises(Manifest::InvalidInventory) { build }
    File.write(@mountinfo, "12 1 0:30 / #{@mount} rw - tmpfs tmpfs rw\n")
    assert_raises(Manifest::InvalidInventory) { build }
  end

  def test_second_daemon_inventory_detects_stop_start_and_group_move
    assert(Manifest.same_inventory?([@ct], [@ct.dup]))
    refute(Manifest.same_inventory?([@ct], []))
    refute(Manifest.same_inventory?([@ct], [@ct.merge(init_pid: 124)]))
    refute(Manifest.same_inventory?([@ct], [@ct.merge(group_path: 'new/path')]))
  end

  def test_atomic_private_publication_and_failed_refresh_preserves_old_snapshot
    directory = File.join(@tmp, 'output')
    Dir.mkdir(directory, 0o700)
    target = File.join(directory, 'roots.json')
    snapshot = build
    Manifest.publish(target, snapshot, owner: Process.euid)
    assert_equal(0o600, File.stat(target).mode & 0o777)
    assert_equal(10, JSON.parse(File.read(target))['generated_monotonic_ns'])
    write_init(state: 'Z')
    assert_raises(Manifest::InvalidInventory) do
      Manifest.publish(target, build(now: 20), owner: Process.euid)
    end
    assert_equal(10, JSON.parse(File.read(target))['generated_monotonic_ns'])
    assert_equal(['roots.json'], Dir.children(directory))
  end

  def test_symlink_output_and_nonprivate_directory_are_rejected
    directory = File.join(@tmp, 'output')
    Dir.mkdir(directory, 0o700)
    target = File.join(directory, 'roots.json')
    File.symlink(File.join(@tmp, 'victim'), target)
    assert_raises(Manifest::InvalidInventory) { Manifest.publish(target, build, owner: Process.euid) }
    File.unlink(target)
    File.chmod(0o755, directory)
    assert_raises(Manifest::InvalidInventory) { Manifest.publish(target, build, owner: Process.euid) }
  end
end
