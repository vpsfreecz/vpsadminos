# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/cgroup/param'
require 'osctld/cgroup/params'
require 'osctld/group'
require 'osctld/container/lifecycle'
require 'osctld/utils/assets'
require 'osctld/utils/devices'
require 'osctld/utils/cgroup_params'

module OsCtld
  module Commands
    module Group; end
  end
end

require 'osctld/commands/group/assets'
require 'osctld/commands/group/create'
require 'osctld/commands/group/delete'
require 'osctld/commands/group/list'
require 'osctld/commands/group/show'
require 'osctld/commands/group/set'
require 'osctld/commands/group/unset'
require 'osctld/commands/group/cgparam_apply'
require 'osctld/commands/group/cgparam_list'
require 'osctld/commands/group/cgparam_replace'
require 'osctld/commands/group/device_add'
require 'osctld/commands/group/device_chmod'
require 'osctld/commands/group/device_delete'
require 'osctld/commands/group/device_inherit'
require 'osctld/commands/group/device_list'
require 'osctld/commands/group/device_promote'
require 'osctld/commands/group/device_replace'
require 'osctld/commands/group/device_set_inherit'
require 'osctld/commands/group/device_unset_inherit'
require 'osctld/commands/group/cgparam_set'
require 'osctld/commands/group/cgparam_unset'
require 'osctld/commands/group/cgsubsystems'

RSpec.describe 'group commands' do
  def build_group(name: '/default')
    pool = Struct.new(:name).new('tank')
    attrs = Struct.new(:export).new({ color: 'blue' })
    Struct.new(:name, :pool, :attrs, keyword_init: true) do
      attr_accessor :set_changes, :unset_changes

      def inclusively
        yield
      end

      def configure; end

      def any_container_running?
        true
      end

      def cgroup_policy_tainted?
        false
      end

      def cgroup_policy_state
        nil
      end

      def has_containers?
        false
      end

      def children
        []
      end

      def config_path
        '/groups/default.yml'
      end

      def config_dir
        '/groups/default'
      end

      def groups_in_path
        [self]
      end

      def path
        name
      end

      def root?
        false
      end

      def devices; end

      def export
        { name:, pool: pool.name }
      end

      def manipulate(_holder, block:, &)
        yield
      end

      def exclusively
        yield
      end

      def set(changes)
        self.set_changes = changes
      end

      def unset(changes)
        self.unset_changes = changes
      end
    end.new(name:, pool:, attrs:)
  end

  before do
    stub_daemon
    history = stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
    allow(history).to receive(:log)
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  it 'returns validated assets from the resolved group' do
    grp = build_group
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    command = OsCtld::Commands::Group::Assets.new({ name: '/default', pool: 'tank' }, {})
    allow(command).to receive(:list_and_validate_assets).with(grp).and_return([{ path: '/tmp/x' }])

    expect(command.execute).to eq(status: true, output: [{ path: '/tmp/x' }])
  end

  it 'lists and shows exported groups merged with attrs' do
    grp = build_group
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.each_by_ids(_names, _pool); end

      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:each_by_ids).with(['/default'], 'tank').and_yield(grp)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)

    expect(OsCtld::Commands::Group::List.run(names: ['/default'], pool: 'tank')).to eq(
      status: true,
      output: [{ name: '/default', pool: 'tank', color: 'blue' }]
    )
    expect(OsCtld::Commands::Group::Show.run(name: '/default', pool: 'tank')).to eq(
      status: true,
      output: { name: '/default', pool: 'tank', color: 'blue' }
    )
  end

  it 'delegates device add through manipulate' do
    grp = build_group
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    command = OsCtld::Commands::Group::DeviceAdd.new({ name: '/default', pool: 'tank' }, {})
    allow(command).to receive(:add).with(grp).and_return(status: true, output: nil)

    expect(command.base_execute).to eq(status: true, output: nil)
    expect(command).to have_received(:add).with(grp)
  end

  it 'passes the apply flag to cgparam set based on running containers' do
    grp = build_group
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    command = OsCtld::Commands::Group::CGParamSet.new(
      { name: '/default', pool: 'tank', parameter: 'memory.max', value: '1G' },
      {}
    )
    allow(command).to receive(:set).with(grp, command.opts, apply: true).and_return(status: true, output: nil)

    expect(command.base_execute).to eq(status: true, output: nil)
  end

  it 'creates parent groups on demand and deletes empty groups' do
    pool = Struct.new(:name).new('tank')
    group_class = stub_const('OsCtld::Group', Class.new do
      attr_reader :pool, :name

      def initialize(pool, name, load: false)
        @pool = pool
        @name = name
      end

      def configure; end

      def cgparams
        Struct.new(:imported) do
          def import(params)
            params
          end

          def set(params)
            self.imported = params
          end
        end.new(nil)
      end

      def parents
        []
      end

      def manipulate(_holder, block:, &)
        yield
      end

      def has_containers?
        false
      end

      def children
        []
      end

      def config_path
        '/groups/workers.yml'
      end

      def config_dir
        '/groups/workers'
      end

      def exclusively
        yield
      end
    end)
    pools = stub_const('OsCtld::DB::Pools', Class.new do
      def self.get_or_default(_name); end
    end)
    groups = stub_const('OsCtld::DB::Groups', Class.new do
      def self.contains?(_name, _pool); end

      def self.by_path(_pool, _path); end

      def self.add(_group); end

      def self.find(_name, _pool); end

      def self.remove(_group); end
    end)
    allow(pools).to receive(:get_or_default).with('tank').and_return(pool)
    allow(groups).to receive(:contains?).with('/workers/build', pool).and_return(false)
    allow(groups).to receive(:by_path).with(pool, '/').and_return(true)
    allow(groups).to receive(:by_path).with(pool, '/workers').and_return(nil)
    allow(groups).to receive(:add)

    expect(
      OsCtld::Commands::Group::Create.run(name: '/workers/build', pool: 'tank', parents: true)
    ).to eq(status: true, output: nil)
    expect(groups).to have_received(:add).at_least(:twice)

    grp = build_group(name: '/workers').tap do |g|
      allow(g).to receive_messages(has_containers?: false, children: [])
    end
    allow(groups).to receive(:find).with('/workers', 'tank').and_return(grp)
    allow(groups).to receive(:remove).with(grp)
    allow(File).to receive(:unlink).with('/groups/default.yml')
    allow(Dir).to receive(:rmdir).with('/groups/default')

    expect(OsCtld::Commands::Group::Delete.run(name: '/workers', pool: 'tank')).to eq(status: true, output: nil)
    expect(groups).to have_received(:remove).with(grp)
  end

  it 'filters supported set and unset changes for groups' do
    grp = build_group
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)

    expect(OsCtld::Commands::Group::Set.run(name: '/default', pool: 'tank', attrs: { owner: 'ops' })).to eq(
      status: true,
      output: nil
    )
    expect(grp.set_changes).to eq(attrs: { owner: 'ops' })
    expect(OsCtld::Commands::Group::Unset.run(name: '/default', pool: 'tank', attrs: %w[owner])).to eq(
      status: true,
      output: nil
    )
    expect(grp.unset_changes).to eq(attrs: %w[owner])
  end

  it 'applies cgroup params across the path, delegates list/replace/unset, and exports subsystems' do
    grp = build_group
    allow(grp).to receive(:groups_in_path).and_return([grp, build_group(name: '/default/child')])
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    cgroup = stub_const('OsCtld::CGroup', Class.new do
      def self.v2?; end

      def self.real_subsystem(_name); end

      def self.abs_cgroup_path(_subsystem); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    allow(cgroup).to receive(:v2?).and_return(false)
    allow(cgroup).to receive(:real_subsystem) { |subsystem| subsystem }
    allow(cgroup).to receive(:abs_cgroup_path) { |subsystem| "/sys/fs/cgroup/#{subsystem}" }

    apply = OsCtld::Commands::Group::CGParamApply.new({ name: '/default', pool: 'tank' }, {})
    allow(apply).to receive(:apply_policy_hierarchy)
      .with(
        grp,
        controllers: %i[cpuset cpu_bandwidth],
        recover: true
      )
      .and_return(status: true, output: nil)
    allow(apply).to receive(:do_apply).and_return(status: true, output: nil)
    expect(apply.execute).to eq(status: true, output: nil)
    expect(apply).to have_received(:apply_policy_hierarchy)
      .with(
        grp,
        controllers: %i[cpuset cpu_bandwidth],
        recover: true
      )
    expect(apply).to have_received(:do_apply).twice

    list = OsCtld::Commands::Group::CGParamList.new({ name: '/default', pool: 'tank' }, {})
    allow(list).to receive(:list).with(grp).and_return(status: true, output: [{ parameter: 'memory.max' }])
    expect(list.execute).to eq(status: true, output: [{ parameter: 'memory.max' }])

    replace = OsCtld::Commands::Group::CGParamReplace.new({ name: '/default', pool: 'tank' }, {})
    allow(replace).to receive(:replace).with(grp).and_return(status: true, output: nil)
    expect(replace.execute).to eq(status: true, output: nil)

    unset = OsCtld::Commands::Group::CGParamUnset.new({ name: '/default', pool: 'tank' }, {})
    allow(unset).to receive(:unset).with(grp, unset.opts, reset: true, keep_going: true).and_return(status: true, output: nil)
    expect(unset.base_execute).to eq(status: true, output: nil)

    expect(OsCtld::Commands::Group::CGSubsystems.run).to eq(
      status: true,
      output: {
        'cpu' => '/sys/fs/cgroup/cpu',
        'cpuacct' => '/sys/fs/cgroup/cpuacct',
        'memory' => '/sys/fs/cgroup/memory',
        'pids' => '/sys/fs/cgroup/pids'
      }
    )
  end

  it 'rejects group cpuset writes while a descendant runtime is residual' do
    grp = OsCtld::Group.allocate
    cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-7'],
      true
    )
    cgparams = instance_double(OsCtld::CGroup::Params, detect: cpuset)
    allow(cgparams).to receive(:apply)
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      residuals: [{ 'id' => 'run-1' }]
    )
    ct = Struct.new(:ident, :lifecycle).new('tank:ct1', lifecycle)
    allow(grp).to receive_messages(
      any_container_running?: true,
      cgparams:,
      containers_in_subtree: [ct],
      descendants: [],
      groups_in_path: [grp],
      name: '/default',
      path: '/osctl/pool.tank/group.default',
      cgroup_path: '/osctl/pool.tank/group.default',
      pool: Struct.new(:name).new('tank'),
      cgroup_policy_state: nil,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true,
      taint_cgroup_policy!: true
    )
    allow(grp).to receive(:manipulate) do |_holder, **, &callback|
      callback.call
    end
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    allow(OsCtld::CGroup).to receive(:mkpath)
    command = OsCtld::Commands::Group::CGParamApply.new(
      { name: '/default', pool: 'tank' },
      {}
    )
    hierarchy = instance_double(
      OsCtld::CGroup::GroupCpusetPolicy,
      applied?: false,
      apply: true
    )
    allow(OsCtld::CGroup::GroupCpusetPolicy).to receive(:new)
      .and_return(hierarchy)
    policy_calls = []
    allow(grp).to receive(:begin_cgroup_policy_update!) do |**opts|
      policy_calls << [:begin, opts]
      true
    end
    allow(grp).to receive(:containers_in_subtree) do
      policy_calls << :snapshot
      [ct]
    end
    allow(grp).to receive(:restore_cgroup_policy_state!) do |state|
      policy_calls << [:restore, state]
      true
    end

    expect(command.execute).to match(
      status: false,
      message: a_string_matching(
        /tank:ct1 has residual runtime cgroups/
      )
    )
    expect(policy_calls).to eq(
      [
        [
          :begin,
          {
            kind: :group_cpuset,
            cleanup_params: [],
            policy_anchors: { cpuset: '/default' }
          }
        ],
        :snapshot,
        [:restore, nil]
      ]
    )
    expect(cgparams).not_to have_received(:apply)
    expect(grp).not_to have_received(:taint_cgroup_policy!)
  end

  it 'recovers a quarantined group with no configured cpuset' do
    grp = OsCtld::Group.allocate
    child_a = OsCtld::Group.allocate
    child_b = OsCtld::Group.allocate
    cgparams = instance_double(
      OsCtld::CGroup::Params,
      detect: nil,
      reset: nil,
      apply: nil
    )
    leaked_pids = OsCtld::CGroup::Param.new(
      2,
      nil,
      'pids.max',
      ['100'],
      true
    )
    allow(cgparams).to receive(:each) { [leaked_pids].each }
    child_cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-1'],
      true
    )
    child_params = instance_double(
      OsCtld::CGroup::Params,
      detect: child_cpuset
    )
    allow(child_params).to receive(:each) { [child_cpuset].each }
    original_state = {
      'status' => 'updating',
      'kind' => 'group_cpuset',
      'cleanup_params' => [leaked_pids.dump],
      'policy_anchors' => { 'cpuset' => '/default' }
    }
    tainted = true
    policy_state = original_state
    allow(grp).to receive_messages(
      any_container_running?: false,
      cgparams:,
      containers_in_subtree: [],
      descendants: [child_a, child_b],
      groups_in_path: [grp],
      name: '/default',
      path: '/osctl/pool.tank/group.default',
      cgroup_path: '/osctl/pool.tank/group.default',
      pool: Struct.new(:name).new('tank'),
      begin_cgroup_policy_update!: original_state,
      clear_cgroup_policy_state!: true,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true,
      abs_cgroup_path: '/sys/fs/cgroup/group.default'
    )
    [child_a, child_b].each_with_index do |child, i|
      allow(child).to receive_messages(
        cgparams: child_params,
        descendants: [],
        groups_in_path: [grp, child],
        name: "/default/child#{i}",
        cgroup_policy_tainted?: false,
        acquire_manipulation_lock: true,
        release_manipulation_lock: true
      )
    end
    allow(grp).to receive(:cgroup_policy_tainted?) { tainted }
    allow(grp).to receive(:cgroup_policy_state) { policy_state }
    allow(grp).to receive(:begin_cgroup_policy_update!) do |**opts|
      tainted = true
      policy_state = {
        'status' => 'updating',
        'kind' => opts.fetch(:kind).to_s,
        'cleanup_params' => opts.fetch(:cleanup_params)
      }
      true
    end
    allow(grp).to receive(:clear_cgroup_policy_state!) do
      tainted = false
      policy_state = nil
      true
    end
    allow(grp).to receive(:manipulate) do |_holder, **, &callback|
      callback.call
    end
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    allow(OsCtld::CGroup).to receive(:mkpath)
    allow(OsCtld::CGroup::GroupCpusetPolicy).to receive(:new)
    command = OsCtld::Commands::Group::CGParamApply.new(
      { name: '/default', pool: 'tank' },
      {}
    )

    expect(
      command.send(:apply, grp, only_cpuset: true)
    ).to match(
      status: false,
      message: a_string_matching(/group cgroup policy is quarantined/)
    )
    expect(grp).not_to have_received(:clear_cgroup_policy_state!)

    expect(command.execute).to eq(status: true, output: nil)
    expect(OsCtld::CGroup).to have_received(:mkpath).with(
      'cpuset',
      ['', 'osctl', 'pool.tank', 'group.default'],
      leaf: false
    )
    expect(OsCtld::CGroup::GroupCpusetPolicy).not_to have_received(:new)
    expect(cgparams).to have_received(:reset).with(
      have_attributes(
        version: 2,
        subsystem: nil,
        name: 'pids.max'
      ),
      true
    )
    expect(cgparams).to have_received(:reset).with(
      have_attributes(
        version: 2,
        subsystem: 'cpuset',
        name: 'cpuset.cpus'
      ),
      true
    )
    expect(cgparams).to have_received(:apply).with(
      keep_going: false,
      cpuset: false,
      only_cpuset: false,
      cpu_bandwidth: false,
      force_cpu_bandwidth: false,
      policy_containers: nil
    )
    expect(grp).to have_received(:clear_cgroup_policy_state!).twice
  end

  it 'does not refence descendants when the group cpuset already matches' do
    grp = OsCtld::Group.allocate
    cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-3'],
      true
    )
    cgparams = instance_double(OsCtld::CGroup::Params, detect: cpuset, apply: nil)
    allow(cgparams).to receive(:each) { [cpuset].each }
    lifecycle = instance_spy(
      OsCtld::Container::Lifecycle,
      residuals: [],
      policy_tainted?: false
    )
    ct = Struct.new(:ident, :lifecycle).new('tank:ct1', lifecycle)
    allow(grp).to receive_messages(
      any_container_running?: false,
      cgparams:,
      containers_in_subtree: [ct],
      descendants: [],
      groups_in_path: [grp],
      name: '/default',
      path: '/osctl/pool.tank/group.default',
      pool: Struct.new(:name).new('tank'),
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true,
      abs_cgroup_path: '/sys/fs/cgroup/group.default'
    )
    allow(grp).to receive(:manipulate) do |_holder, **, &callback|
      callback.call
    end
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:read_effective_mask)
      .with('/sys/fs/cgroup/group.default')
      .and_return('0-3')
    allow(File).to receive(:read)
      .with('/sys/fs/cgroup/group.default/cpuset.cpus')
      .and_return('0-3')
    command = OsCtld::Commands::Group::CGParamApply.new(
      { name: '/default', pool: 'tank' },
      {}
    )
    hierarchy = instance_double(
      OsCtld::CGroup::GroupCpusetPolicy,
      applied?: true
    )
    allow(OsCtld::CGroup::GroupCpusetPolicy).to receive(:new)
      .and_return(hierarchy)

    allow(lifecycle).to receive(:begin_parent_policy_update)
    expect(command.execute).to eq(status: true, output: nil)
    expect(cgparams).not_to have_received(:apply)
    expect(lifecycle).not_to have_received(:begin_parent_policy_update)

    allow(OsCtld::CGroup::CpusetPolicy).to receive(:read_effective_mask)
      .with('/sys/fs/cgroup/group.default')
      .and_return('0-1')
    expect(command.send(:group_cpuset_applied?, grp)).to be(false)

    allow(OsCtld::CGroup::CpusetPolicy).to receive(:read_effective_mask)
      .with('/sys/fs/cgroup/group.default')
      .and_return('0-3')
    allow(File).to receive(:read)
      .with('/sys/fs/cgroup/group.default/cpuset.cpus')
      .and_return('')
    expect(command.send(:group_cpuset_applied?, grp)).to be(false)
  end

  it 'allows transactional set, unset, and replace to repair quarantine' do
    valid_cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-3'],
      true
    )
    original_state = {
      'status' => 'tainted',
      'kind' => 'group_cpuset',
      'cleanup_params' => [],
      'policy_anchors' => { 'cpuset' => '/default' }
    }
    allow(OsCtld::CGroup).to receive_messages(
      version: 2,
      mkpath_all: true
    )

    build_quarantined = lambda do |cgparams|
      OsCtld::Group.allocate.tap do |grp|
        allow(grp).to receive_messages(
          cgparams:,
          containers_in_subtree: [],
          descendants: [],
          groups_in_path: [grp],
          name: '/default',
          cgroup_path: '/osctl/pool.tank/group.default',
          cgroup_policy_tainted?: true,
          cgroup_policy_state: original_state,
          begin_cgroup_policy_update!: original_state,
          clear_cgroup_policy_state!: true,
          acquire_manipulation_lock: true,
          release_manipulation_lock: true,
          abs_cgroup_path: '/sys/fs/cgroup/group.default'
        )
        allow(grp).to receive(:manipulate) do |_holder, **, &callback|
          callback.call
        end
      end
    end

    set_params = instance_double(
      OsCtld::CGroup::Params,
      import: [valid_cpuset],
      each: [valid_cpuset].each,
      transactional_set: nil
    )
    set_group = build_quarantined.call(set_params)
    set_command = OsCtld::Commands::Group::CGParamSet.new({}, {})
    expect(
      set_command.send(
        :set,
        set_group,
        {
          parameters: [valid_cpuset.export],
          append: false
        },
        apply: true
      )
    ).to eq(status: true, output: nil)
    expect(set_params).to have_received(:transactional_set).with(
      [valid_cpuset],
      append: false,
      apply: true,
      cpuset: true,
      cpu_bandwidth: false,
      force_cpu_bandwidth: false,
      policy_containers: []
    )
    expect(set_group).to have_received(:clear_cgroup_policy_state!)

    unset_params = instance_double(
      OsCtld::CGroup::Params,
      each: [valid_cpuset].each,
      transactional_unset: nil
    )
    unset_group = build_quarantined.call(unset_params)
    unset_command = OsCtld::Commands::Group::CGParamUnset.new({}, {})
    expect(
      unset_command.send(
        :unset,
        unset_group,
        { parameters: [valid_cpuset.export] },
        reset: true,
        keep_going: true
      )
    ).to eq(status: true, output: nil)
    expect(unset_params).to have_received(:transactional_unset).with(
      [valid_cpuset.export],
      reset: true,
      keep_going: true,
      apply_all: true,
      cpuset: true,
      cpu_bandwidth: false,
      force_cpu_bandwidth: false,
      policy_containers: []
    )
    expect(unset_group).to have_received(:clear_cgroup_policy_state!)

    replace_params = instance_double(
      OsCtld::CGroup::Params,
      import: [valid_cpuset],
      each: [valid_cpuset].each,
      transactional_replace: nil
    )
    replace_group = build_quarantined.call(replace_params)
    replace_command = OsCtld::Commands::Group::CGParamReplace.new(
      { parameters: [valid_cpuset.export] },
      {}
    )
    expect(replace_command.send(:replace, replace_group)).to eq(
      status: true,
      output: nil
    )
    expect(replace_params).to have_received(:transactional_replace).with(
      [valid_cpuset],
      cpuset: true,
      cpu_bandwidth: false,
      force_cpu_bandwidth: false,
      policy_containers: []
    )
    expect(replace_group).to have_received(:clear_cgroup_policy_state!)
  end

  it 'quarantines an incomplete guarded group apply' do
    grp = OsCtld::Group.allocate
    cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-3'],
      true
    )
    cgparams = instance_double(OsCtld::CGroup::Params, detect: cpuset)
    pids = OsCtld::CGroup::Param.new(
      2,
      'pids',
      'pids.max',
      ['100'],
      true
    )
    allow(cgparams).to receive(:each) { [cpuset, pids].each }
    allow(cgparams).to receive(:apply)
      .and_raise(
        OsCtld::CGroup::CpusetPolicy::Error,
        'kernel rejected pids.max'
      )
    allow(grp).to receive_messages(
      any_container_running?: false,
      cgparams:,
      containers_in_subtree: [],
      descendants: [],
      groups_in_path: [grp],
      name: '/default',
      path: '/osctl/pool.tank/group.default',
      cgroup_path: '/osctl/pool.tank/group.default',
      pool: Struct.new(:name).new('tank'),
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil,
      begin_cgroup_policy_update!: true,
      taint_cgroup_policy!: true,
      clear_cgroup_policy_state!: true,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true,
      abs_cgroup_path: '/sys/fs/cgroup/group.default'
    )
    allow(grp).to receive(:manipulate) do |_holder, **, &callback|
      callback.call
    end
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    allow(OsCtld::CGroup).to receive_messages(version: 2, mkpath: true)
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:read_effective_mask)
      .and_return('0-1')
    command = OsCtld::Commands::Group::CGParamApply.new(
      { name: '/default', pool: 'tank' },
      {}
    )
    hierarchy = instance_double(
      OsCtld::CGroup::GroupCpusetPolicy,
      applied?: false,
      apply: true
    )
    allow(OsCtld::CGroup::GroupCpusetPolicy).to receive(:new)
      .and_return(hierarchy)

    expect(command.execute).to match(
      status: false,
      message: 'kernel rejected pids.max'
    )
    expect(grp).to have_received(:taint_cgroup_policy!).with(
      kind: :group_cgroup_params,
      error: 'kernel rejected pids.max',
      rollback_error: 'runtime group policy apply did not complete',
      cleanup_params: []
    )
    expect(grp).to have_received(:clear_cgroup_policy_state!).once
  end

  it 'recovers a generic marker without interpreting descendant policies' do
    grp = OsCtld::Group.allocate
    child_a = OsCtld::Group.allocate
    child_b = OsCtld::Group.allocate
    pids = OsCtld::CGroup::Param.new(
      2,
      'pids',
      'pids.max',
      ['100'],
      true
    )
    cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-1'],
      true
    )
    cgparams = instance_double(
      OsCtld::CGroup::Params,
      apply: nil,
      detect: nil
    )
    child_params = instance_double(OsCtld::CGroup::Params, detect: cpuset)
    allow(cgparams).to receive(:each) { [pids].each }
    allow(child_params).to receive(:each) { [cpuset].each }
    state = {
      'status' => 'tainted',
      'kind' => 'group_cgroup_params',
      'cleanup_params' => []
    }
    allow(grp).to receive_messages(
      any_container_running?: false,
      cgparams:,
      containers_in_subtree: [],
      descendants: [child_a, child_b],
      groups_in_path: [grp],
      name: '/default',
      path: '/osctl/pool.tank/group.default',
      pool: Struct.new(:name).new('tank'),
      cgroup_path: '/osctl/pool.tank/group.default',
      acquire_manipulation_lock: true,
      release_manipulation_lock: true,
      abs_cgroup_path: '/sys/fs/cgroup/group.default'
    )
    allow(grp).to receive(:cgroup_policy_state) { state }
    allow(grp).to receive(:cgroup_policy_tainted?) { !state.nil? }
    allow(grp).to receive(:begin_cgroup_policy_update!) do |**opts|
      state = {
        'status' => 'updating',
        'kind' => opts.fetch(:kind).to_s,
        'cleanup_params' => opts.fetch(:cleanup_params)
      }
      true
    end
    allow(grp).to receive(:clear_cgroup_policy_state!) do
      state = nil
      true
    end
    [child_a, child_b].each_with_index do |child, i|
      allow(child).to receive_messages(
        cgparams: child_params,
        descendants: [],
        groups_in_path: [grp, child],
        name: "/default/child#{i}",
        cgroup_policy_tainted?: false,
        acquire_manipulation_lock: true,
        release_manipulation_lock: true
      )
    end
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    allow(OsCtld::CGroup::GroupCpusetPolicy).to receive(:new)
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
    command = OsCtld::Commands::Group::CGParamApply.new(
      { name: '/default', pool: 'tank' },
      {}
    )

    expect(command.execute).to eq(status: true, output: nil)
    expect(state).to be_nil
    expect(cgparams).to have_received(:apply).once
    expect(OsCtld::CGroup::GroupCpusetPolicy).not_to have_received(:new)
    expect(
      OsCtld::CGroup::GroupCpuBandwidthPolicy
    ).not_to have_received(:new)
  end

  it 'rechecks a generic recovery marker after acquiring group locks' do
    pids = OsCtld::CGroup::Param.new(
      2,
      'pids',
      'pids.max',
      ['100'],
      true
    )

    [
      [:cleared, nil, true],
      [
        :replaced,
        {
          'status' => 'tainted',
          'kind' => 'group_cpu_bandwidth',
          'cleanup_params' => []
        },
        false
      ]
    ].each do |_scenario, locked_state, succeeds|
      grp = OsCtld::Group.allocate
      cgparams = instance_double(
        OsCtld::CGroup::Params,
        apply: nil,
        detect: nil
      )
      allow(cgparams).to receive(:each) { [pids].each }
      state = {
        'status' => 'tainted',
        'kind' => 'group_cgroup_params',
        'cleanup_params' => []
      }
      allow(grp).to receive_messages(
        any_container_running?: false,
        cgparams:,
        containers_in_subtree: [],
        descendants: [],
        groups_in_path: [grp],
        name: '/default',
        path: '/osctl/pool.tank/group.default',
        pool: Struct.new(:name).new('tank'),
        cgroup_path: '/osctl/pool.tank/group.default',
        release_manipulation_lock: true,
        abs_cgroup_path: '/sys/fs/cgroup/group.default'
      )
      allow(grp).to receive(:cgroup_policy_state) { state }
      allow(grp).to receive(:cgroup_policy_tainted?) { !state.nil? }
      allow(grp).to receive(:acquire_manipulation_lock) do
        state = locked_state
        true
      end
      allow(grp).to receive(:begin_cgroup_policy_update!) do |**opts|
        state = {
          'status' => 'updating',
          'kind' => opts.fetch(:kind).to_s,
          'cleanup_params' => opts.fetch(:cleanup_params)
        }
        true
      end
      allow(grp).to receive(:clear_cgroup_policy_state!) do
        state = nil
        true
      end
      db = stub_const('OsCtld::DB::Groups', Class.new do
        def self.find(_name, _pool); end
      end)
      allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
      allow(OsCtld::CGroup).to receive(:version).and_return(2)
      command = OsCtld::Commands::Group::CGParamApply.new(
        { name: '/default', pool: 'tank' },
        {}
      )

      ret = command.execute
      if succeeds
        expect(ret).to eq(status: true, output: nil)
        expect(cgparams).to have_received(:apply).once
        expect(grp).to have_received(:begin_cgroup_policy_update!).once
      else
        expect(ret).to match(
          status: false,
          message: a_string_matching(/cgroup policy is quarantined/)
        )
        expect(cgparams).not_to have_received(:apply)
        expect(grp).not_to have_received(:begin_cgroup_policy_update!)
      end
    end
  end

  it 'does not fence a same-value CPU set with unrelated memory' do
    grp = OsCtld::Group.allocate
    current_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['250000 100000'],
      true
    )
    same_cpu = current_cpu.clone
    memory = OsCtld::CGroup::Param.new(
      2,
      'memory',
      'memory.max',
      ['1G'],
      true
    )
    cgparams = instance_double(
      OsCtld::CGroup::Params,
      import: [same_cpu, memory],
      set: nil
    )
    allow(cgparams).to receive(:each) { [current_cpu].each }
    allow(grp).to receive_messages(
      cgparams:,
      groups_in_path: [grp],
      descendants: [],
      name: '/default',
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true
    )
    allow(grp).to receive(:manipulate) do |_holder, **, &callback|
      callback.call
    end
    allow(grp).to receive(:begin_cgroup_policy_update!)
    command = OsCtld::Commands::Group::CGParamSet.new({}, {})
    allow(command).to receive(:group_cpu_bandwidth_applied?)
      .with(grp)
      .and_return(true)
    allow(command).to receive(:apply)
      .with(grp, cpuset: false, cpu_bandwidth: false)
      .and_return(status: true, output: nil)

    expect(
      command.send(
        :set,
        grp,
        {
          parameters: [same_cpu.export, memory.export],
          append: false
        },
        apply: true
      )
    ).to eq(status: true, output: nil)
    expect(cgparams).to have_received(:set).with(
      [same_cpu, memory],
      append: false
    )
    expect(grp).not_to have_received(:begin_cgroup_policy_update!)
  end

  it 'rejects generic set, unset, and replace across any overlapping marker' do
    memory = OsCtld::CGroup::Param.new(
      2,
      'memory',
      'memory.max',
      ['1G'],
      true
    )
    marker_state = {
      'status' => 'tainted',
      'kind' => 'group_cpu_bandwidth',
      'cleanup_params' => []
    }
    operations = [
      [
        :set,
        OsCtld::Commands::Group::CGParamSet,
        proc do |command, group|
          command.send(
            :set,
            group,
            {
              parameters: [memory.export],
              append: false
            },
            apply: true
          )
        end
      ],
      [
        :unset,
        OsCtld::Commands::Group::CGParamUnset,
        proc do |command, group|
          command.send(
            :unset,
            group,
            { parameters: [memory.export] },
            reset: true,
            keep_going: true
          )
        end
      ],
      [
        :replace,
        OsCtld::Commands::Group::CGParamReplace,
        proc { |command, group| command.send(:replace, group) }
      ]
    ]

    %i[exact ancestor descendant].each do |marker_position|
      operations.each do |mutation, command_class, invoke|
        root = OsCtld::Group.allocate
        child = OsCtld::Group.allocate
        target =
          case marker_position
          when :ancestor
            child
          else
            root
          end
        marked =
          case marker_position
          when :descendant
            child
          else
            root
          end
        cgparams = instance_double(
          OsCtld::CGroup::Params,
          import: [memory],
          set: nil,
          unset: nil,
          replace: nil
        )
        allow(cgparams).to receive(:each) { [memory].each }
        allow(root).to receive_messages(
          descendants: [child],
          groups_in_path: [root],
          name: '/default',
          cgroup_policy_tainted?: root == marked,
          cgroup_policy_state: root == marked ? marker_state : nil,
          acquire_manipulation_lock: true,
          release_manipulation_lock: true
        )
        allow(child).to receive_messages(
          descendants: [],
          groups_in_path: [root, child],
          name: '/default/child',
          cgroup_policy_tainted?: child == marked,
          cgroup_policy_state: child == marked ? marker_state : nil,
          acquire_manipulation_lock: true,
          release_manipulation_lock: true
        )
        allow(target).to receive(:cgparams).and_return(cgparams)
        command_opts =
          if mutation == :replace
            { parameters: [memory.export] }
          else
            {}
          end
        command = command_class.new(command_opts, {})

        expect(invoke.call(command, target)).to match(
          status: false,
          message: a_string_matching(/cgroup policy is quarantined/)
        )
        expect(cgparams).not_to have_received(mutation)
      end
    end
  end

  it 'allows a generic apply only under its exact same-group marker' do
    grp = OsCtld::Group.allocate
    pids = OsCtld::CGroup::Param.new(
      2,
      'pids',
      'pids.max',
      ['100'],
      true
    )
    cgparams = instance_double(
      OsCtld::CGroup::Params,
      apply: nil
    )
    allow(cgparams).to receive(:each) { [pids].each }
    marker = nil
    allow(grp).to receive_messages(
      cgparams:,
      descendants: [],
      groups_in_path: [grp],
      name: '/default',
      path: '/osctl/pool.tank/group.default',
      pool: Struct.new(:name).new('tank'),
      cgroup_policy_tainted?: false,
      containers_in_subtree: [],
      acquire_manipulation_lock: true,
      release_manipulation_lock: true
    )
    allow(grp).to receive(:cgroup_policy_state) { marker }
    allow(grp).to receive(:begin_cgroup_policy_update!) do |**args|
      marker = {
        'status' => 'updating',
        'kind' => args.fetch(:kind).to_s,
        'cleanup_params' => []
      }
    end
    allow(grp).to receive(:clear_cgroup_policy_state!) { marker = nil }
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    command = OsCtld::Commands::Group::CGParamApply.new({}, {})

    expect(
      command.send(:do_apply, grp, false, guarded: true)
    ).to eq(status: true, output: nil)
    expect(cgparams).to have_received(:apply).with(
      keep_going: false,
      cpuset: false,
      only_cpuset: false,
      cpu_bandwidth: false,
      force_cpu_bandwidth: false,
      policy_containers: nil
    )
    expect(marker).to be_nil
  end

  it 'does not treat another group as proof of an existing marker guard' do
    root = OsCtld::Group.allocate
    child = OsCtld::Group.allocate
    pids = OsCtld::CGroup::Param.new(
      2,
      'pids',
      'pids.max',
      ['100'],
      true
    )
    cgparams = instance_double(OsCtld::CGroup::Params, apply: nil)
    allow(cgparams).to receive(:each) { [pids].each }
    state = {
      'status' => 'updating',
      'kind' => 'group_cgroup_policy',
      'cleanup_params' => []
    }
    allow(root).to receive_messages(
      descendants: [child],
      groups_in_path: [root],
      name: '/default',
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil
    )
    allow(child).to receive_messages(
      cgparams:,
      descendants: [],
      groups_in_path: [root, child],
      name: '/default/child',
      cgroup_policy_tainted?: true,
      cgroup_policy_state: state
    )
    command = OsCtld::Commands::Group::CGParamApply.new({}, {})

    expect(
      command.send(
        :apply,
        child,
        cpuset: false,
        cpu_bandwidth: false,
        group_policy_guarded: root
      )
    ).to match(
      status: false,
      message: a_string_matching(/cgroup policy is quarantined/)
    )
    expect(cgparams).not_to have_received(:apply)
  end

  it 'decides set, unset, and replace policy scope after taking group locks' do
    old_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['100000 100000'],
      true
    )
    changed_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['200000 100000'],
      true
    )
    cases = [
      [
        :transactional_set,
        OsCtld::Commands::Group::CGParamSet,
        [],
        [changed_cpu],
        old_cpu,
        proc do |command, group|
          command.send(
            :set,
            group,
            {
              parameters: [old_cpu.export],
              append: false
            },
            apply: true
          )
        end
      ],
      [
        :transactional_unset,
        OsCtld::Commands::Group::CGParamUnset,
        [],
        [old_cpu],
        nil,
        proc do |command, group|
          command.send(
            :unset,
            group,
            { parameters: [old_cpu.export] },
            reset: true,
            keep_going: true
          )
        end
      ],
      [
        :transactional_replace,
        OsCtld::Commands::Group::CGParamReplace,
        [old_cpu],
        [changed_cpu],
        old_cpu,
        proc { |command, group| command.send(:replace, group) }
      ]
    ]

    cases.each do |transaction, command_class, before_lock, after_lock,
                   imported, invoke|
      grp = OsCtld::Group.allocate
      current = before_lock.dup
      cgparams = instance_double(
        OsCtld::CGroup::Params,
        import: imported ? [imported] : [],
        transactional_set: nil,
        transactional_unset: nil,
        transactional_replace: nil
      )
      allow(cgparams).to receive(:each) { current.each }
      allow(grp).to receive_messages(
        cgparams:,
        descendants: [],
        groups_in_path: [grp],
        name: '/default',
        containers_in_subtree: [],
        cgroup_path: '/osctl/pool.tank/group.default',
        cgroup_policy_tainted?: false,
        cgroup_policy_state: nil,
        begin_cgroup_policy_update!: true,
        clear_cgroup_policy_state!: true,
        release_manipulation_lock: true,
        abs_cgroup_path: '/sys/fs/cgroup/group.default'
      )
      allow(grp).to receive(:acquire_manipulation_lock) do
        current.replace(after_lock)
        true
      end
      allow(OsCtld::CGroup).to receive(:version).and_return(2)
      command_opts =
        if transaction == :transactional_replace
          { parameters: [old_cpu.export] }
        else
          {}
        end
      command = command_class.new(command_opts, {})

      expect(invoke.call(command, grp)).to eq(status: true, output: nil)
      expect(cgparams).to have_received(transaction).once
      marker = {
        kind: :group_cpu_bandwidth,
        cleanup_params: [],
        policy_anchors: { cpu_bandwidth: '/default' }
      }
      if transaction == :transactional_unset
        marker[:cpu_bandwidth_resets] = [old_cpu.dump]
        marker[:cpu_bandwidth_reset_target] = []
      end
      expect(grp).to have_received(:begin_cgroup_policy_update!).once.with(
        **marker
      )
    end
  end

  it 'replays a CPU reset only after its staged configuration is durable' do
    grp = OsCtld::Group.allocate
    quota = OsCtld::CGroup::Param.new(
      1,
      'cpu',
      'cpu.cfs_quota_us',
      ['250000'],
      true
    )
    period = OsCtld::CGroup::Param.new(
      1,
      'cpu',
      'cpu.cfs_period_us',
      ['200000'],
      true
    )
    current = [period]
    marker = {
      'status' => 'tainted',
      'kind' => 'group_cpu_bandwidth',
      'cleanup_params' => [],
      'cpu_bandwidth_resets' => [quota.dump],
      'cpu_bandwidth_reset_target' => [period.dump]
    }
    cgparams = instance_double(OsCtld::CGroup::Params)
    allow(cgparams).to receive(:each) { current.each }
    allow(grp).to receive_messages(
      cgparams:,
      cgroup_policy_state: marker
    )
    allow(OsCtld::CGroup).to receive(:version).and_return(1)
    command = OsCtld::Commands::Group::CGParamApply.new({}, {})

    expect(
      command.send(:applicable_group_cpu_resets, grp)
    ).to contain_exactly(
      have_attributes(version: 1, name: 'cpu.cfs_quota_us')
    )

    current.replace([quota, period])

    expect(
      command.send(:applicable_group_cpu_resets, grp)
    ).to be_empty
  end

  it 'quarantines a group when reconstruction cannot be compensated' do
    grp = OsCtld::Group.allocate
    current_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['100000 100000'],
      true
    )
    new_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['200000 100000'],
      true
    )
    reconstruction_error =
      OsCtld::CGroup::CpuBandwidthPolicy::Error.new(
        'CPU reconstruction cannot be rolled back exactly'
      )
    policy_error = OsCtld::CGroup::CpuBandwidthPolicy::Error.new(
      'injected CPU policy failure',
      rollback_error: reconstruction_error
    )
    failing_policy = instance_double(
      OsCtld::CGroup::GroupCpuBandwidthPolicy
    )
    recovery_policy = instance_double(
      OsCtld::CGroup::GroupCpuBandwidthPolicy,
      apply: true
    )
    allow(failing_policy).to receive(:apply).and_raise(policy_error)
    cgparams = OsCtld::CGroup::Params.new(
      grp,
      params: [current_cpu]
    )
    allow(cgparams).to receive(:import).and_return([new_cpu])
    allow(grp).to receive_messages(
      cgparams:,
      descendants: [],
      groups_in_path: [grp],
      name: '/default',
      containers_in_subtree: [],
      cgroup_path: '/osctl/pool.tank/group.default',
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil,
      begin_cgroup_policy_update!: true,
      taint_cgroup_policy!: true,
      clear_cgroup_policy_state!: true,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true,
      abs_cgroup_path: '/sys/fs/cgroup/group.default',
      save_config: true
    )
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .with(grp, reconstruct_to: grp, containers: [])
      .and_return(failing_policy, recovery_policy)
    command = OsCtld::Commands::Group::CGParamSet.new({}, {})

    expect(
      command.send(
        :set,
        grp,
        {
          parameters: [new_cpu.export],
          append: false
        },
        apply: true
      )
    ).to match(
      status: false,
      message: /injected CPU policy failure/
    )
    expect(grp).to have_received(:taint_cgroup_policy!).with(
      kind: :group_cpu_bandwidth,
      error: a_string_matching(/injected CPU policy failure/),
      rollback_error:
        'CPU reconstruction cannot be rolled back exactly',
      cleanup_params: []
    )
    expect(grp).not_to have_received(:clear_cgroup_policy_state!)
    expect(cgparams.each.map(&:value)).to eq(
      [['100000 100000']]
    )
  end

  it 'records the exact cpuset anchor for unset and replace mutations' do
    cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-3'],
      true
    )
    cases = [
      [
        :transactional_unset,
        OsCtld::Commands::Group::CGParamUnset,
        {},
        proc do |command, group|
          command.send(
            :unset,
            group,
            { parameters: [cpuset.export] },
            reset: true,
            keep_going: true
          )
        end
      ],
      [
        :transactional_replace,
        OsCtld::Commands::Group::CGParamReplace,
        { parameters: [] },
        proc { |command, group| command.send(:replace, group) }
      ]
    ]

    cases.each do |transaction, command_class, command_opts, invoke|
      grp = OsCtld::Group.allocate
      cgparams = instance_double(
        OsCtld::CGroup::Params,
        import: [],
        transactional_unset: nil,
        transactional_replace: nil
      )
      allow(cgparams).to receive(:each) { [cpuset].each }
      allow(grp).to receive_messages(
        cgparams:,
        descendants: [],
        groups_in_path: [grp],
        name: '/default',
        containers_in_subtree: [],
        cgroup_path: '/osctl/pool.tank/group.default',
        cgroup_policy_tainted?: false,
        cgroup_policy_state: nil,
        begin_cgroup_policy_update!: true,
        clear_cgroup_policy_state!: true,
        acquire_manipulation_lock: true,
        release_manipulation_lock: true,
        abs_cgroup_path: '/sys/fs/cgroup/group.default'
      )
      allow(OsCtld::CGroup).to receive(:version).and_return(2)
      command = command_class.new(command_opts, {})

      expect(invoke.call(command, grp)).to eq(status: true, output: nil)
      expect(cgparams).to have_received(transaction).once
      expect(grp).to have_received(:begin_cgroup_policy_update!).once.with(
        kind: :group_cpuset,
        cleanup_params: [],
        policy_anchors: { cpuset: '/default' }
      )
    end
  end

  it 'requires full apply to recover a mutation with mixed anchors' do
    root = OsCtld::Group.allocate
    child = OsCtld::Group.allocate
    current_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['250000 100000'],
      true
    )
    new_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['200000 100000'],
      true
    )
    cgparams = instance_double(
      OsCtld::CGroup::Params,
      import: [new_cpu],
      transactional_set: nil
    )
    allow(cgparams).to receive(:each) { [current_cpu].each }
    state = {
      'status' => 'tainted',
      'kind' => 'group_cgroup_policy',
      'cleanup_params' => [],
      'policy_anchors' => {
        'cpu_bandwidth' => '/default',
        'cpuset' => '/default/child'
      }
    }
    allow(root).to receive_messages(
      cgparams:,
      descendants: [child],
      groups_in_path: [root],
      name: '/default',
      cgroup_policy_tainted?: true,
      cgroup_policy_state: state,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true
    )
    allow(root).to receive(:begin_cgroup_policy_update!)
    allow(child).to receive_messages(
      descendants: [],
      groups_in_path: [root, child],
      name: '/default/child',
      cgroup_policy_tainted?: false,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true
    )
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    command = OsCtld::Commands::Group::CGParamSet.new({}, {})

    expect(
      command.send(
        :set,
        root,
        {
          parameters: [new_cpu.export],
          append: false
        },
        apply: true
      )
    ).to match(
      status: false,
      message: a_string_matching(/different recorded cpuset anchor/)
    )
    expect(cgparams).not_to have_received(:transactional_set)
    expect(root).not_to have_received(:begin_cgroup_policy_update!)
  end

  it 'uses one combined marker and lease for cpuset and CPU mutation' do
    grp = OsCtld::Group.allocate
    current_cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-3'],
      true
    )
    new_cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-1'],
      true
    )
    current_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['250000 100000'],
      true
    )
    new_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['200000 100000'],
      true
    )
    cgparams = instance_double(
      OsCtld::CGroup::Params,
      import: [new_cpuset, new_cpu],
      transactional_set: nil
    )
    allow(cgparams).to receive(:each) do
      [current_cpuset, current_cpu].each
    end
    lease = OsCtld::Container::Lifecycle::PolicyLease.new(
      id: 'lease-1',
      revision: 1
    )
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      residuals: [],
      policy_tainted?: false,
      begin_parent_policy_update: lease,
      finish_parent_policy_update: nil
    )
    ct = Struct.new(:ident, :lifecycle).new('tank:ct1', lifecycle)
    allow(grp).to receive_messages(
      cgparams:,
      descendants: [],
      groups_in_path: [grp],
      name: '/default',
      containers_in_subtree: [ct],
      cgroup_path: '/osctl/pool.tank/group.default',
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil,
      begin_cgroup_policy_update!: true,
      clear_cgroup_policy_state!: true,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true,
      abs_cgroup_path: '/sys/fs/cgroup/group.default'
    )
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    command = OsCtld::Commands::Group::CGParamSet.new({}, {})

    expect(
      command.send(
        :set,
        grp,
        {
          parameters: [new_cpuset.export, new_cpu.export],
          append: false
        },
        apply: true
      )
    ).to eq(status: true, output: nil)
    expect(grp).to have_received(:begin_cgroup_policy_update!).once.with(
      kind: :group_cgroup_policy,
      cleanup_params: [],
      policy_anchors: {
        cpuset: '/default',
        cpu_bandwidth: '/default'
      }
    )
    expect(lifecycle).to have_received(:begin_parent_policy_update).once.with(
      kind: :group_cgroup_policy,
      allow_residuals: false
    )
    expect(cgparams).to have_received(:transactional_set).with(
      [new_cpuset, new_cpu],
      append: false,
      apply: true,
      cpuset: true,
      cpu_bandwidth: true,
      force_cpu_bandwidth: false,
      policy_containers: [ct]
    )
  end

  it 'admits a CPU-only group mutation with unrelated cpuset and residuals' do
    grp = OsCtld::Group.allocate
    cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-3'],
      true
    )
    current_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['250000 100000'],
      true
    )
    new_cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['400000 100000'],
      true
    )
    cgparams = instance_double(
      OsCtld::CGroup::Params,
      import: [new_cpu],
      transactional_set: nil
    )
    allow(cgparams).to receive(:each) { [cpuset, current_cpu].each }
    lease = OsCtld::Container::Lifecycle::PolicyLease.new(
      id: 'lease-1',
      revision: 1
    )
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      residuals: [{ 'id' => 'run-1' }],
      policy_tainted?: false,
      begin_parent_policy_update: lease,
      finish_parent_policy_update: nil
    )
    ct = Struct.new(:ident, :lifecycle).new('tank:ct1', lifecycle)
    allow(grp).to receive_messages(
      cgparams:,
      descendants: [],
      groups_in_path: [grp],
      name: '/default',
      containers_in_subtree: [ct],
      cgroup_path: '/osctl/pool.tank/group.default',
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil,
      begin_cgroup_policy_update!: true,
      clear_cgroup_policy_state!: true,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true,
      abs_cgroup_path: '/sys/fs/cgroup/group.default'
    )
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    command = OsCtld::Commands::Group::CGParamSet.new({}, {})

    expect(
      command.send(
        :set,
        grp,
        {
          parameters: [new_cpu.export],
          append: false
        },
        apply: true
      )
    ).to eq(status: true, output: nil)
    expect(grp).to have_received(:begin_cgroup_policy_update!).with(
      kind: :group_cpu_bandwidth,
      cleanup_params: [],
      policy_anchors: { cpu_bandwidth: '/default' }
    )
    expect(lifecycle).to have_received(:begin_parent_policy_update).with(
      kind: :group_cpu_bandwidth,
      allow_residuals: true
    )
    expect(cgparams).to have_received(:transactional_set).with(
      [new_cpu],
      append: false,
      apply: true,
      cpuset: false,
      cpu_bandwidth: true,
      force_cpu_bandwidth: false,
      policy_containers: [ct]
    )
  end

  it 'recovers a CPU-only marker without invoking cpuset recovery' do
    grp = OsCtld::Group.allocate
    cgparams = instance_double(
      OsCtld::CGroup::Params,
      detect: nil,
      reset: nil,
      apply: nil
    )
    allow(cgparams).to receive(:each) { [].each }
    state = {
      'status' => 'tainted',
      'kind' => 'group_cpu_bandwidth',
      'cleanup_params' => []
    }
    allow(grp).to receive_messages(
      any_container_running?: false,
      cgparams:,
      containers_in_subtree: [],
      descendants: [],
      groups_in_path: [grp],
      name: '/default',
      path: '/osctl/pool.tank/group.default',
      cgroup_path: '/osctl/pool.tank/group.default',
      pool: Struct.new(:name).new('tank'),
      cgroup_policy_tainted?: true,
      cgroup_policy_state: state,
      begin_cgroup_policy_update!: true,
      clear_cgroup_policy_state!: true,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true,
      abs_cgroup_path: '/sys/fs/cgroup/group.default'
    )
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    policy = instance_double(
      OsCtld::CGroup::GroupCpuBandwidthPolicy,
      applied?: true,
      preflight!: true,
      apply: true
    )
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .with(grp, reconstruct_to: grp, containers: nil)
      .and_return(policy)
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .with(grp, reconstruct_to: grp, containers: [])
      .and_return(policy)
    allow(OsCtld::CGroup::GroupCpusetPolicy).to receive(:new)
    command = OsCtld::Commands::Group::CGParamApply.new(
      { name: '/default', pool: 'tank' },
      {}
    )

    expect(command.execute).to eq(status: true, output: nil)
    expect(grp).to have_received(:begin_cgroup_policy_update!).with(
      kind: :group_cpu_bandwidth,
      cleanup_params: [],
      policy_anchors: { cpu_bandwidth: '/default' }
    )
    expect(policy).to have_received(:apply)
    expect(OsCtld::CGroup::GroupCpusetPolicy).not_to have_received(:new)
    expect(cgparams).not_to have_received(:reset)
  end

  it 'recovers distinct CPU and cpuset anchors from one durable marker' do
    root = OsCtld::Group.allocate
    child = OsCtld::Group.allocate
    cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['250000 100000'],
      true
    )
    cpuset = OsCtld::CGroup::Param.new(
      2,
      'cpuset',
      'cpuset.cpus',
      ['0-3'],
      true
    )
    root_params = instance_double(OsCtld::CGroup::Params, detect: cpu)
    child_params = instance_double(OsCtld::CGroup::Params, detect: cpuset)
    allow(root_params).to receive(:each) { [cpu].each }
    allow(child_params).to receive(:each) { [cpuset].each }
    marker = {
      'status' => 'tainted',
      'kind' => 'group_cgroup_policy',
      'cleanup_params' => [],
      'policy_anchors' => {
        'cpu_bandwidth' => '/default',
        'cpuset' => '/default/child'
      }
    }
    allow(root).to receive_messages(
      any_container_running?: false,
      cgparams: root_params,
      containers_in_subtree: [],
      descendants: [child],
      groups_in_path: [root],
      name: '/default',
      path: '/osctl/pool.tank/group.default',
      cgroup_path: '/osctl/pool.tank/group.default',
      pool: Struct.new(:name).new('tank'),
      cgroup_policy_tainted?: true,
      cgroup_policy_state: marker,
      begin_cgroup_policy_update!: true,
      clear_cgroup_policy_state!: true,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true,
      abs_cgroup_path: '/sys/fs/cgroup/group.default'
    )
    allow(child).to receive_messages(
      cgparams: child_params,
      descendants: [],
      groups_in_path: [root, child],
      name: '/default/child',
      cgroup_path: '/osctl/pool.tank/group.default/group.child',
      cgroup_policy_tainted?: false,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true
    )
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(root)
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    cpu_policy = instance_double(
      OsCtld::CGroup::GroupCpuBandwidthPolicy,
      applied?: false,
      preflight!: true,
      apply: true
    )
    cpuset_policy = instance_double(
      OsCtld::CGroup::GroupCpusetPolicy,
      applied?: false,
      apply: true
    )
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .with(root, reconstruct_to: root, containers: nil)
      .and_return(cpu_policy)
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .with(root, reconstruct_to: root, containers: [])
      .and_return(cpu_policy)
    allow(OsCtld::CGroup::GroupCpusetPolicy).to receive(:new)
      .with(child, reconstruct_to: child)
      .and_return(cpuset_policy)
    command = OsCtld::Commands::Group::CGParamApply.new(
      {
        name: '/default',
        pool: 'tank',
        only_policies: true
      },
      {}
    )

    expect(command.execute).to eq(status: true, output: nil)
    expect(root).to have_received(:begin_cgroup_policy_update!).with(
      kind: :group_cgroup_policy,
      cleanup_params: [],
      policy_anchors: {
        'cpuset' => '/default/child',
        'cpu_bandwidth' => '/default'
      }
    )
    expect(cpu_policy).to have_received(:apply)
    expect(cpuset_policy).to have_received(:apply)
  end

  it 'constructs the fenced CPU policy from the post-marker membership' do
    root = OsCtld::Group.allocate
    child = OsCtld::Group.allocate
    cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['250000 100000'],
      true
    )
    root_params = instance_double(OsCtld::CGroup::Params, detect: cpu)
    child_params = instance_double(OsCtld::CGroup::Params, detect: nil)
    allow(root_params).to receive(:each) { [cpu].each }
    allow(child_params).to receive(:each) { [].each }
    lease = OsCtld::Container::Lifecycle::PolicyLease.new(
      id: 'lease-1',
      revision: 1
    )
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      residuals: [],
      policy_tainted?: false,
      begin_parent_policy_update: lease,
      finish_parent_policy_update: nil
    )
    ct = Struct.new(:ident, :lifecycle).new('tank:ct1', lifecycle)
    order = []
    allow(root).to receive_messages(
      cgparams: root_params,
      descendants: [child],
      groups_in_path: [root],
      name: '/default',
      cgroup_path: '/osctl/pool.tank/group.default',
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil,
      clear_cgroup_policy_state!: true,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true
    )
    allow(child).to receive_messages(
      any_container_running?: true,
      cgparams: child_params,
      descendants: [],
      groups_in_path: [root, child],
      name: '/default/child',
      cgroup_path: '/osctl/pool.tank/group.default/group.child',
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true
    )
    allow(root).to receive(:begin_cgroup_policy_update!) do
      order << :marker
      true
    end
    allow(root).to receive(:containers_in_subtree) do
      order << :membership
      [ct]
    end
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find)
      .with('/default/child', 'tank')
      .and_return(child)
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    initial_policy = instance_double(
      OsCtld::CGroup::GroupCpuBandwidthPolicy,
      applied?: false,
      preflight!: true
    )
    fenced_policy = instance_double(
      OsCtld::CGroup::GroupCpuBandwidthPolicy,
      applied?: false,
      apply: true
    )
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .with(root, reconstruct_to: child, containers: nil)
      .and_return(initial_policy)
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .with(root, reconstruct_to: child, containers: [ct])
      .and_return(fenced_policy)
    command = OsCtld::Commands::Group::CGParamApply.new(
      {
        name: '/default/child',
        pool: 'tank',
        only_policies: true
      },
      {}
    )

    expect(command.execute).to eq(status: true, output: nil)
    expect(order).to eq(%i[marker membership])
    expect(fenced_policy).to have_received(:apply)
    expect(lifecycle).to have_received(:begin_parent_policy_update).with(
      kind: :group_cpu_bandwidth,
      allow_residuals: true
    )
  end

  it 'does not publish a marker when CPU preflight rejects without writes' do
    grp = OsCtld::Group.allocate
    cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['250000 100000'],
      true
    )
    cgparams = instance_double(OsCtld::CGroup::Params, detect: cpu)
    allow(cgparams).to receive(:each) { [cpu].each }
    allow(grp).to receive_messages(
      any_container_running?: false,
      cgparams:,
      descendants: [],
      groups_in_path: [grp],
      name: '/default',
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true
    )
    allow(grp).to receive(:begin_cgroup_policy_update!)
    allow(grp).to receive(:taint_cgroup_policy!)
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    policy = instance_double(
      OsCtld::CGroup::GroupCpuBandwidthPolicy,
      applied?: false
    )
    allow(policy).to receive(:preflight!)
      .and_raise(
        OsCtld::CGroup::CpuBandwidthPolicy::Error,
        'impossible live CPU transition'
      )
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .with(grp, reconstruct_to: grp, containers: nil)
      .and_return(policy)
    command = OsCtld::Commands::Group::CGParamApply.new(
      {
        name: '/default',
        pool: 'tank',
        only_policies: true
      },
      {}
    )

    expect(command.execute).to match(
      status: false,
      message: 'impossible live CPU transition'
    )
    expect(grp).not_to have_received(:begin_cgroup_policy_update!)
    expect(grp).not_to have_received(:taint_cgroup_policy!)
  end

  it 'refuses an ancestor policy apply across a descendant quarantine' do
    root = OsCtld::Group.allocate
    child = OsCtld::Group.allocate
    cpu = OsCtld::CGroup::Param.new(
      2,
      'cpu',
      'cpu.max',
      ['250000 100000'],
      true
    )
    cgparams = instance_double(OsCtld::CGroup::Params, detect: cpu)
    allow(root).to receive_messages(
      any_container_running?: false,
      cgparams:,
      descendants: [child],
      groups_in_path: [root],
      name: '/default',
      cgroup_policy_tainted?: false,
      cgroup_policy_state: nil,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true
    )
    allow(child).to receive_messages(
      name: '/default/child',
      cgroup_policy_tainted?: true,
      acquire_manipulation_lock: true,
      release_manipulation_lock: true
    )
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(root)
    allow(OsCtld::CGroup).to receive(:version).and_return(2)
    command = OsCtld::Commands::Group::CGParamApply.new(
      { name: '/default', pool: 'tank' },
      {}
    )
    allow(root).to receive(:begin_cgroup_policy_update!)

    expect(command.execute).to match(
      status: false,
      message: a_string_matching(
        %r{quarantined at /default/child.*apply that exact group}
      )
    )
    expect(root).not_to have_received(:begin_cgroup_policy_update!)
  end

  it 'delegates the remaining device helpers through manipulate or inclusively' do
    grp = build_group
    device = Struct.new(:inherited?).new(false)
    devices = Struct.new(:removed) do
      def find(_type, _major, _minor)
        Struct.new(:inherited?).new(false)
      end

      def used_by_descendants?(_device)
        false
      end

      def remove(dev)
        self.removed = dev
      end
    end.new(nil)
    allow(grp).to receive(:devices).and_return(devices)
    db = stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('/default', 'tank').and_return(grp)

    [
      [OsCtld::Commands::Group::DeviceChmod, :chmod],
      [OsCtld::Commands::Group::DeviceInherit, :inherit],
      [OsCtld::Commands::Group::DevicePromote, :promote],
      [OsCtld::Commands::Group::DeviceReplace, :replace],
      [OsCtld::Commands::Group::DeviceSetInherit, :set_inherit],
      [OsCtld::Commands::Group::DeviceUnsetInherit, :unset_inherit]
    ].each do |klass, method_name|
      command = klass.new({ name: '/default', pool: 'tank' }, {})
      allow(command).to receive(method_name).with(grp).and_return(status: true, output: nil)
      expect(command.base_execute).to eq(status: true, output: nil)
    end

    list = OsCtld::Commands::Group::DeviceList.new({ name: '/default', pool: 'tank' }, {})
    allow(list).to receive(:list).with(grp, list.opts).and_return(status: true, output: [{ type: 'c' }])
    expect(list.execute).to eq(status: true, output: [{ type: 'c' }])

    delete = OsCtld::Commands::Group::DeviceDel.new(
      { name: '/default', pool: 'tank', type: 'c', major: 1, minor: 3, recursive: false },
      {}
    )
    expect(delete.base_execute).to eq(status: true, output: nil)
    expect(devices.removed).not_to be_nil
  end
end

# rubocop:enable RSpec/DescribeClass
