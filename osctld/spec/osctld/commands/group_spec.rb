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
    allow(apply).to receive(:apply_cpuset_hierarchy)
      .with(grp, recover: true)
      .and_return(status: true, output: nil)
    allow(apply).to receive(:apply).and_return(status: true, output: nil)
    expect(apply.execute).to eq(status: true, output: nil)
    expect(apply).to have_received(:apply_cpuset_hierarchy)
      .with(grp, recover: true)
    expect(apply).to have_received(:apply).twice

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
      applied?: true
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
        [:begin, { kind: :group_cpuset, cleanup_params: [] }],
        :snapshot,
        [:restore, nil]
      ]
    )
    expect(cgparams).not_to have_received(:apply)
    expect(grp).not_to have_received(:taint_cgroup_policy!)
  end

  it 'recovers a quarantined group with no configured cpuset' do
    grp = OsCtld::Group.allocate
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
    original_state = {
      'status' => 'updating',
      'kind' => 'group_cpuset',
      'cleanup_params' => [leaked_pids.dump]
    }
    allow(grp).to receive_messages(
      any_container_running?: false,
      cgparams:,
      containers_in_subtree: [],
      groups_in_path: [grp],
      name: '/default',
      path: '/osctl/pool.tank/group.default',
      cgroup_path: '/osctl/pool.tank/group.default',
      pool: Struct.new(:name).new('tank'),
      cgroup_policy_tainted?: true,
      cgroup_policy_state: original_state,
      begin_cgroup_policy_update!: original_state,
      clear_cgroup_policy_state!: true,
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
    allow(OsCtld::CGroup).to receive(:mkpath_all)
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
    expect(OsCtld::CGroup).to have_received(:mkpath_all).with(
      ['', 'osctl', 'pool.tank', 'group.default'],
      leaf: false
    )
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
      false
    )
    expect(cgparams).to have_received(:apply).with(
      keep_going: false,
      cpuset: false,
      only_cpuset: false
    )
    expect(grp).to have_received(:clear_cgroup_policy_state!)
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
    expect(cgparams).to have_received(:apply).with(
      keep_going: false,
      cpuset: false,
      only_cpuset: false
    )
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
      'cleanup_params' => []
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
          cgroup_path: '/osctl/pool.tank/group.default',
          cgroup_policy_tainted?: true,
          cgroup_policy_state: original_state,
          begin_cgroup_policy_update!: original_state,
          clear_cgroup_policy_state!: true,
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
      apply: true
    )
    expect(set_group).to have_received(:clear_cgroup_policy_state!)

    unset_params = instance_double(
      OsCtld::CGroup::Params,
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
      apply_all: true
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
      [valid_cpuset]
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
      applied?: true
    )
    allow(OsCtld::CGroup::GroupCpusetPolicy).to receive(:new)
      .and_return(hierarchy)

    expect(command.execute).to match(
      status: false,
      message: 'kernel rejected pids.max'
    )
    expect(grp).to have_received(:taint_cgroup_policy!).with(
      kind: :group_cpuset,
      error: 'kernel rejected pids.max',
      rollback_error: 'runtime group policy apply did not complete',
      cleanup_params: []
    )
    expect(grp).not_to have_received(:clear_cgroup_policy_state!)
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
