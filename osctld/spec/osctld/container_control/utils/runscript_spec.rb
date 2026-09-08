# frozen_string_literal: true

require 'osctld/container_control/command'

module OsCtld
  module ContainerControl
    module Utils; end
  end
end

require 'osctld/container_control/utils/runscript'

RSpec.describe OsCtld::ContainerControl::Utils::Runscript::Frontend do
  subject(:frontend) { frontend_class.new(ct) }

  let(:container_class) do
    Class.new do
      def current_state; end

      def running?; end
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
    let(:ct) { instance_double(container_class, current_state: :stopped) }

    it 'refreshes state after transient execution' do
      frontend.sync_state_after_transient_run(:run)

      expect(ct).to have_received(:current_state)
    end

    it 'does not refresh state after running-container execution' do
      frontend.sync_state_after_transient_run(:running)

      expect(ct).not_to have_received(:current_state)
    end
  end
end
