# frozen_string_literal: true

# rubocop:disable RSpec/MessageSpies, RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles

require 'fileutils'
require 'tmpdir'

module OsCtld
  module Commands
    module Container; end
    module User; end
  end

  module Utils
    module SwitchUser; end
  end

  module DB; end
end

require 'osctld/command'
require 'osctld/exceptions'
require 'osctld/commands/container/delete'

RSpec.describe OsCtld::Commands::Container::Delete do
  let(:root) { Dir.mktmpdir('osctld-delete') }
  let(:autostart_plan) { double(clear_ct: nil) }
  let(:pool) { double(name: 'tank', autostart_plan: autostart_plan, trash_bin: trash_bin) }
  let(:trash_bin) { double(prune: nil) }
  let(:netifs) { double }
  let(:recovery) { double(cleanup_or_taint: true) }
  let(:shared_dir) { double(remove: nil) }
  let(:mounts) { double(shared_dir: shared_dir) }
  let(:group) do
    double(
      has_containers?: true,
      full_cgroup_path: '/osctl/pool.tank/group.default/user.alice'
    )
  end
  let(:user) { double(name: 'alice', standalone: true) }
  let(:ct) do
    double(
      pool: pool,
      id: 'ct1',
      running?: true,
      send_log: nil,
      netifs: netifs,
      clear_start_menu: nil,
      mounts: mounts,
      dataset: 'tank/ct/ct1',
      lxc_dir: File.join(root, 'lxc'),
      user_hook_script_dir: File.join(root, 'hooks'),
      log_path: File.join(root, 'ct.log'),
      config_path: File.join(root, 'ct.conf'),
      group: group,
      user: user,
      base_cgroup_path: '/osctl/pool.tank/ct.ct1'
    )
  end
  let(:cmd) { described_class.new({ id: 'ct1', pool: 'tank', force: true }, { id: 1 }) }

  before do
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.remove(*); end
    end)
    stub_const('OsCtld::Commands::Container::Stop', Class.new)
    stub_const('OsCtld::Commands::User::LxcUsernet', Class.new)
    stub_const('OsCtld::Console', Class.new do
      def self.remove(*); end
    end)
    stub_const('OsCtld::Monitor', Module.new)
    stub_const('OsCtld::Monitor::Master', Class.new do
      def self.demonitor(*); end
    end)
    stub_const('OsCtld::TrashBin', Class.new do
      def self.add_dataset(*); end
    end)
    stub_const('OsCtld::CGroup', Class.new do
      def self.rmpath_all(*); end
    end)
    stub_const('OsCtld::AppArmor', Class.new do
      def self.enabled? = false
    end)
    recovery_class = stub_const('OsCtld::Container::Recovery', Class.new do
      def initialize(_ct); end

      def cleanup_or_taint; end
    end)

    FileUtils.mkdir_p(root)
    FileUtils.touch(ct.config_path)

    allow(cmd).to receive(:manipulate) { |_ct, &block| block.call }
    allow(cmd).to receive(:syscmd)
    allow(cmd).to receive(:call_cmd).with(OsCtld::Commands::User::LxcUsernet).and_return(status: true)

    allow(OsCtld::Monitor::Master).to receive(:demonitor)
    allow(OsCtld::Console).to receive(:remove)
    allow(OsCtld::DB::Containers).to receive(:remove)
    allow(OsCtld::TrashBin).to receive(:add_dataset)
    allow(OsCtld::CGroup).to receive(:rmpath_all)
    allow(OsCtld::AppArmor).to receive(:enabled?).and_return(false)
    allow(recovery_class).to receive(:new).with(ct).and_return(recovery)
  end

  after do
    FileUtils.rm_rf(root)
  end

  it 'requires successful recovery cleanup before removing runtime files' do
    expect(cmd).to receive(:call_cmd!).with(
      OsCtld::Commands::Container::Stop,
      pool: 'tank',
      id: 'ct1',
      manipulation_lock: nil,
      progress: nil,
      message: nil,
      method: 'kill'
    ).ordered.and_return(status: true)
    expect(recovery).to receive(:cleanup_or_taint).ordered.and_return(true)
    expect(OsCtld::Console).to receive(:remove).with(ct).ordered

    ret = cmd.execute(ct)

    expect(ret).to eq(status: true, output: nil)
  end

  it 'keeps runtime files, dataset, and registration when recovery cleanup is tainted' do
    expect(cmd).to receive(:call_cmd!).with(
      OsCtld::Commands::Container::Stop,
      pool: 'tank',
      id: 'ct1',
      manipulation_lock: nil,
      progress: nil,
      message: nil,
      method: 'kill'
    ).ordered.and_return(status: true)
    expect(recovery).to receive(:cleanup_or_taint).ordered.and_return(false)

    expect { cmd.execute(ct) }.to raise_error(
      OsCtld::CommandFailed,
      'Unable to safely complete container cleanup'
    )

    expect(File).to exist(ct.config_path)
    expect(OsCtld::Console).not_to have_received(:remove)
    expect(shared_dir).not_to have_received(:remove)
    expect(OsCtld::TrashBin).not_to have_received(:add_dataset)
    expect(cmd).not_to have_received(:syscmd)
    expect(OsCtld::DB::Containers).not_to have_received(:remove)
  end
end

# rubocop:enable RSpec/MessageSpies, RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles
