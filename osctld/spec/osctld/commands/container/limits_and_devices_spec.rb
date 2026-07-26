# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/utils/devices'
require 'osctld/utils/cgroup_params'

module OsCtld
  module Commands
    module Group; end
  end
end

require 'osctld/commands/container/device_add'
require 'osctld/commands/container/device_delete'
require 'osctld/commands/container/device_list'
require 'osctld/commands/container/device_chmod'
require 'osctld/commands/container/device_inherit'
require 'osctld/commands/container/device_promote'
require 'osctld/commands/container/device_replace'
require 'osctld/commands/container/device_set_inherit'
require 'osctld/commands/container/device_unset_inherit'
require 'osctld/commands/container/cgparam_apply'
require 'osctld/commands/container/cgparam_list'
require 'osctld/commands/container/cgparam_replace'
require 'osctld/commands/container/cgparam_set'
require 'osctld/commands/container/cgparam_unset'
require 'osctld/commands/container/prlimit_list'
require 'osctld/commands/container/prlimit_set'
require 'osctld/commands/container/prlimit_unset'

RSpec.describe 'container limits and device commands' do
  def build_history
    stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
  end

  def build_db_containers
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
  end

  def build_ct(running: false)
    group = Struct.new(:name).new('/default')
    pool = Struct.new(:name).new('tank')
    Struct.new(:group, :pool) do
      attr_accessor :running_state, :devices, :prlimits

      def running?
        running_state
      end

      def manipulate(_holder, block:, &)
        yield
      end

      def inclusively(&block)
        block.call
      end
    end.new(group, pool).tap do |ct|
      ct.running_state = running
    end
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
    allow(build_history).to receive(:log)
  end

  shared_examples 'device helper command' do |command_class, helper_method|
    it "delegates #{helper_method} through manipulate" do
      ct = build_ct
      command = command_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(helper_method).with(ct).and_return(status: true, output: nil)

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(command).to have_received(helper_method).with(ct)
    end
  end

  describe OsCtld::Commands::Container::DeviceAdd do
    it_behaves_like 'device helper command', described_class, :add
  end

  describe OsCtld::Commands::Container::DeviceChmod do
    it_behaves_like 'device helper command', described_class, :chmod
  end

  describe OsCtld::Commands::Container::DeviceInherit do
    it_behaves_like 'device helper command', described_class, :inherit
  end

  describe OsCtld::Commands::Container::DevicePromote do
    it_behaves_like 'device helper command', described_class, :promote
  end

  describe OsCtld::Commands::Container::DeviceReplace do
    it_behaves_like 'device helper command', described_class, :replace
  end

  describe OsCtld::Commands::Container::DeviceSetInherit do
    it_behaves_like 'device helper command', described_class, :set_inherit
  end

  describe OsCtld::Commands::Container::DeviceUnsetInherit do
    it_behaves_like 'device helper command', described_class, :unset_inherit
  end

  describe OsCtld::Commands::Container::DeviceList do
    it 'errors when the container cannot be found' do
      db = build_db_containers
      allow(db).to receive(:find).with('ct1', 'tank').and_return(nil)

      expect { described_class.run(id: 'ct1', pool: 'tank') }
        .to raise_error(OsCtld::CommandFailed, 'container not found')
    end

    it 'delegates device export to the helper within an inclusive read lock' do
      db = build_db_containers
      ct = build_ct
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:list).with(ct, command.opts).and_return(status: true, output: [{ type: 'char' }])

      expect(command.execute).to eq(status: true, output: [{ type: 'char' }])
    end
  end

  describe OsCtld::Commands::Container::DeviceDelete do
    it 'rejects deleting inherited devices' do
      ct = build_ct
      device = Struct.new do
        def inherited?
          true
        end
      end.new
      ct.devices = Struct.new do
        def find(*); end
      end.new
      allow(ct.devices).to receive(:find).with(:char, 1, 3).and_return(device)
      command = described_class.new({ type: 'char', major: 1, minor: 3 }, {})

      expect { command.execute(ct) }
        .to raise_error(
          OsCtld::CommandFailed,
          'inherited devices cannot be removed, use chmod to restrict access'
        )
    end

    it 'removes matched non-inherited devices' do
      ct = build_ct
      device = Struct.new do
        def inherited?
          false
        end
      end.new
      ct.devices = Struct.new do
        def find(*); end

        def remove(_dev); end
      end.new
      allow(ct.devices).to receive(:find).with(:block, 8, 1).and_return(device)
      allow(ct.devices).to receive(:remove).with(device)
      command = described_class.new({ type: 'block', major: 8, minor: 1 }, {})

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.devices).to have_received(:remove).with(device)
    end
  end

  describe OsCtld::Commands::Container::CGParamApply do
    it 'passes through group command failures' do
      db = build_db_containers
      group_apply = stub_const('OsCtld::Commands::Group::CGParamApply', Class.new)
      ct = build_ct(running: true)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:call_cmd)
        .with(group_apply, name: '/default', pool: 'tank')
        .and_return(status: false, message: 'group failed')
      allow(command).to receive(:apply)

      expect(command.execute).to eq(status: false, message: 'group failed')
      expect(command).not_to have_received(:apply)
    end

    it 'applies container parameters with force based on running state after group success' do
      db = build_db_containers
      group_apply = stub_const('OsCtld::Commands::Group::CGParamApply', Class.new)
      ct = build_ct(running: true)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:call_cmd)
        .with(group_apply, name: '/default', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:apply)
        .with(ct, force: true, cpuset: true)
        .and_return(status: true, output: nil)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:apply).with(
        ct,
        force: true,
        cpuset: true
      )
    end

    it 'passes through container parameter failures' do
      db = build_db_containers
      group_apply = stub_const('OsCtld::Commands::Group::CGParamApply', Class.new)
      ct = build_ct(running: true)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:call_cmd)
        .with(group_apply, name: '/default', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:apply)
        .with(ct, force: true, cpuset: true)
        .and_return(status: false, message: 'container apply failed')

      expect(command.execute).to eq(
        status: false,
        message: 'container apply failed'
      )
    end
  end

  describe OsCtld::Commands::Container::CGParamList do
    it 'delegates list requests to the cgroup helper' do
      db = build_db_containers
      ct = build_ct
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:list).with(ct).and_return(status: true, output: { 'memory.max' => '1G' })

      expect(command.execute).to eq(status: true, output: { 'memory.max' => '1G' })
    end
  end

  describe OsCtld::Commands::Container::CGParamReplace do
    it 'delegates replace requests to the cgroup helper' do
      db = build_db_containers
      ct = build_ct
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:replace).with(ct).and_return(status: true, output: nil)

      expect(command.execute).to eq(status: true, output: nil)
    end
  end

  describe OsCtld::Commands::Container::CGParamSet do
    it 'passes apply based on running state' do
      ct = build_ct(running: false)
      command = described_class.new({ parameter: 'memory.max', value: '1G' }, {})
      allow(command).to receive(:set).with(ct, command.opts, apply: false).and_return(status: true, output: nil)

      expect(command.execute(ct)).to eq(status: true, output: nil)
    end
  end

  describe OsCtld::Commands::Container::CGParamUnset do
    it 'requests reset and keep_going when unsetting parameters' do
      ct = build_ct
      command = described_class.new({ parameter: 'memory.max' }, {})
      allow(command).to receive(:unset)
        .with(ct, command.opts, reset: true, keep_going: true)
        .and_return(status: true, output: nil)

      expect(command.execute(ct)).to eq(status: true, output: nil)
    end
  end

  describe OsCtld::Commands::Container::PrLimitList do
    it 'exports only requested limits' do
      db = build_db_containers
      ct = build_ct
      ct.prlimits = {
        'nofile' => Struct.new(:name) do
          def export
            { soft: 1024, hard: 2048 }
          end
        end.new('nofile'),
        'nproc' => Struct.new(:name) do
          def export
            { soft: 256, hard: 512 }
          end
        end.new('nproc')
      }
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      command = described_class.new({ id: 'ct1', pool: 'tank', limits: ['nofile'] }, {})

      expect(command.execute).to eq(
        status: true,
        output: { 'nofile' => { soft: 1024, hard: 2048 } }
      )
    end
  end

  describe OsCtld::Commands::Container::PrLimitSet do
    it 'parses limits and stores them through the container limit manager' do
      ct = build_ct
      ct.prlimits = Struct.new do
        def set(*); end
      end.new
      allow(ct.prlimits).to receive(:set).with('nofile', 1024, 2048)
      command = described_class.new({ name: 'nofile', soft: 1024, hard: 2048 }, {})

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.prlimits).to have_received(:set).with('nofile', 1024, 2048)
    end

    it 'accepts a finite soft limit with an unlimited hard limit' do
      ct = build_ct
      ct.prlimits = Struct.new do
        def set(*); end
      end.new
      allow(ct.prlimits).to receive(:set).with('nofile', 1024, 'unlimited')
      command = described_class.new({ name: 'nofile', soft: 1024, hard: 'unlimited' }, {})

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.prlimits).to have_received(:set).with('nofile', 1024, 'unlimited')
    end

    it 'rejects an unlimited soft limit with a finite hard limit' do
      command = described_class.new({ name: 'nofile', soft: 'unlimited', hard: 2048 }, {})

      expect { command.execute(build_ct) }
        .to raise_error(OsCtld::CommandFailed, 'soft cannot be unlimited when hard is finite')
    end

    it 'stores unlimited as a string for downstream prlimit consumers' do
      ct = build_ct
      ct.prlimits = Struct.new do
        def set(*); end
      end.new
      allow(ct.prlimits).to receive(:set).with('nofile', 'unlimited', 'unlimited')
      command = described_class.new({ name: 'nofile', soft: 'unlimited', hard: 'unlimited' }, {})

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.prlimits).to have_received(:set).with('nofile', 'unlimited', 'unlimited')
    end
  end

  describe OsCtld::Commands::Container::PrLimitUnset do
    it 'unsets the selected limit' do
      ct = build_ct
      ct.prlimits = Struct.new do
        def unset(*); end
      end.new
      allow(ct.prlimits).to receive(:unset).with('nofile')
      command = described_class.new({ name: 'nofile' }, {})

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.prlimits).to have_received(:unset).with('nofile')
    end
  end
end

# rubocop:enable RSpec/DescribeClass
