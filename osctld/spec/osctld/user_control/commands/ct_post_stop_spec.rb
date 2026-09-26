# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles

require 'osctld/exceptions'
require 'osctld/console'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/ct_post_stop'

RSpec.describe OsCtld::UserControl::Commands::CtPostStop do
  let(:user) { Object.new }
  let(:rc) { Object.new }
  let(:ct) { double(id: 'ct1', user: user, pool: double(name: 'tank'), run_conf: rc, stopped: true) }
  let(:command) { described_class.new(user, id: 'ct1', pool: 'tank', target: 'stop') }

  before do
    stub_const('OsCtld::DB::Containers', double(find: ct))
    stub_const('OsCtld::AppArmor', double(enabled?: false))
    stub_const('OsCtld::Hook', double(run: nil))
    allow(OsCtld::BpfFs).to receive(:remove_ct)
    allow(OsCtld::Console).to receive(:handles_run?).with(ct, rc).and_return(false)
    allow(OsCtld::Container::StopHandler).to receive(:schedule)
  end

  it 'schedules real exit cleanup after retiring a direct-start run and running its hook' do
    expect(command.execute).to eq(status: true, output: nil)
    expect(ct).to have_received(:stopped).with(rc).ordered
    expect(OsCtld::Hook).to have_received(:run).with(ct, :post_stop).ordered
    expect(OsCtld::Container::StopHandler).to have_received(:schedule).with(ct, rc).ordered
  end

  it 'leaves a console-owned run to its wrapper exit callback' do
    allow(OsCtld::Console).to receive(:handles_run?).with(ct, rc).and_return(true)

    expect(command.execute).to eq(status: true, output: nil)
    expect(OsCtld::Container::StopHandler).not_to have_received(:schedule)
  end

  it 'still schedules cleanup if the user post-stop hook fails' do
    allow(OsCtld::Hook).to receive(:run).and_raise('hook failed')

    expect { command.execute }.to raise_error(RuntimeError, 'hook failed')
    expect(OsCtld::Container::StopHandler).to have_received(:schedule).with(ct, rc)
  end

  it 'does not schedule cleanup if run retirement fails' do
    allow(ct).to receive(:stopped).and_raise('retirement failed')

    expect { command.execute }.to raise_error(RuntimeError, 'retirement failed')
    expect(OsCtld::Container::StopHandler).not_to have_received(:schedule)
  end

  it 'does not mutate a foreign container' do
    allow(ct).to receive(:user).and_return(Object.new)

    expect(command.execute).to eq(status: false, message: 'access denied')
    expect(OsCtld::BpfFs).not_to have_received(:remove_ct)
    expect(OsCtld::Container::StopHandler).not_to have_received(:schedule)
  end
end

# rubocop:enable RSpec/VerifiedDoubles
