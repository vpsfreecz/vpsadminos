# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass

require 'osctld/exceptions'
require 'osctld/command'
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
    allow(apply).to receive(:apply).and_return(status: true, output: nil)
    expect(apply.execute).to eq(status: true, output: nil)
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
