# frozen_string_literal: true

require 'osctld/container_control/command'

module OsCtld
  module ContainerControl
    module Utils; end
  end
end

require 'osctld/container_control/utils/runscript'
require 'osctld/container_control/commands/exec'
require 'osctld/container_control/commands/runscript'
require 'osctld/promise'

RSpec.describe OsCtld::ContainerControl::Utils::Runscript::Frontend do
  subject(:frontend) { frontend_class.new(ct) }

  let(:container_class) do
    Class.new do
      def current_state; end

      def running?; end

      def get_exit_promise; end
    end
  end

  let(:frontend_class) do
    Class.new do
      include OsCtld::ContainerControl::Utils::Runscript::Frontend

      attr_reader :ct

      def initialize(ct)
        @ct = ct
      end
    end
  end

  describe '#runscript_mode' do
    context 'when transient execution is enabled' do
      let(:ct) { instance_double(container_class, current_state: :stopped) }

      it 'uses the current LXC state before selecting run mode' do
        expect(frontend.runscript_mode(run: true, network: false)).to eq(:run)
        expect(ct).to have_received(:current_state)
      end

      it 'selects networked run mode for stopped containers' do
        expect(frontend.runscript_mode(run: true, network: true)).to eq(:run_network)
      end
    end

    it 'selects running mode when the current LXC state is running' do
      ct = instance_double(container_class, current_state: :running)
      frontend = frontend_class.new(ct)

      expect(frontend.runscript_mode(run: true, network: true)).to eq(:running)
    end

    it 'uses cached state for non-transient execution' do
      ct = instance_double(container_class, running?: true)
      frontend = frontend_class.new(ct)

      expect(frontend.runscript_mode(run: false, network: false)).to eq(:running)
    end

    it 'rejects stopped containers without transient execution' do
      ct = instance_double(container_class, running?: false)
      frontend = frontend_class.new(ct)

      expect do
        frontend.runscript_mode(run: false, network: false)
      end.to raise_error(OsCtld::ContainerControl::Error, 'container not running')
    end
  end

  describe '#sync_state_after_transient_run' do
    let(:ct) { instance_double(container_class, current_state: :stopped, get_exit_promise: nil) }

    it 'refreshes state after transient execution' do
      frontend.sync_state_after_transient_run(:run)

      expect(ct).to have_received(:current_state)
    end

    %i[run run_network].each do |mode|
      it "waits for exit cleanup before completing #{mode}" do
        token = instance_double(OsCtld::Promise::Token, wait: true)
        allow(ct).to receive(:get_exit_promise).and_return(token)

        frontend.sync_state_after_transient_run(mode)

        expect(ct).to have_received(:current_state).ordered
        expect(ct).to have_received(:get_exit_promise).ordered
        expect(token).to have_received(:wait).with(timeout: 30).ordered
      end

      it "fails closed when exit cleanup does not complete for #{mode}" do
        token = instance_double(OsCtld::Promise::Token, wait: nil)
        allow(ct).to receive(:get_exit_promise).and_return(token)

        expect do
          frontend.sync_state_after_transient_run(mode)
        end.to raise_error(OsCtld::ContainerControl::Error, 'Transient container cleanup has not finished')
      end
    end

    it 'does not refresh state after running-container execution' do
      frontend.sync_state_after_transient_run(:running)

      expect(ct).not_to have_received(:current_state)
      expect(ct).not_to have_received(:get_exit_promise)
    end
  end
end

[
  OsCtld::ContainerControl::Commands::Exec::Frontend,
  OsCtld::ContainerControl::Commands::Runscript::Frontend
].each do |frontend_class|
  RSpec.describe frontend_class do
    subject(:frontend) { described_class.new(nil, Object.new) }

    it 'removes temporary scripts even when exit cleanup times out' do
      result = instance_double(OsCtld::ContainerControl::Result, ok?: true, data: 0)
      allow(frontend).to receive_messages(runscript_mode: :running, exec_runner: result, cleanup_init_script: nil)
      allow(frontend).to receive(:sync_state_after_transient_run)
        .and_raise(OsCtld::ContainerControl::Error, 'Transient container cleanup has not finished')

      if described_class == OsCtld::ContainerControl::Commands::Runscript::Frontend
        script = instance_double(File, path: '/fixture/.runscript-test.sh', close: nil)
        allow(frontend).to receive_messages(copy_script: script, unlink_file: nil)
      end

      expect do
        frontend.execute(run: false, network: false, cmd: ['true'], script: '/fixture/payload', args: [])
      end.to raise_error(OsCtld::ContainerControl::Error, 'Transient container cleanup has not finished')

      expect(frontend).to have_received(:cleanup_init_script)
      if script
        expect(script).to have_received(:close)
        expect(frontend).to have_received(:unlink_file).with(script.path)
      end
    end
  end
end
