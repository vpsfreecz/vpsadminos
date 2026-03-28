# frozen_string_literal: true

require 'osctld/user_control/supervisor'

RSpec.describe OsCtld::UserControl::Supervisor do
  def build_service_pair
    server_class = Class.new do
      def stop; end
    end

    [
      instance_double(server_class, stop: nil),
      instance_double(Thread, join: nil)
    ]
  end

  subject(:supervisor) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set('@mutex', Mutex.new)
      instance.instance_variable_set('@servers', servers)
    end
  end

  let(:namespaced_server) { build_service_pair }
  let(:user_server) { build_service_pair }
  let(:servers) do
    {
      namespaced: namespaced_server,
      'alice' => user_server
    }
  end

  describe '#stop_all' do
    it 'stops and joins each server exactly once' do
      supervisor.stop_all

      expect(namespaced_server[0]).to have_received(:stop).once
      expect(namespaced_server[1]).to have_received(:join).once
      expect(user_server[0]).to have_received(:stop).once
      expect(user_server[1]).to have_received(:join).once
    end

    it 'stays safe when only the namespaced server exists' do
      supervisor.instance_variable_set('@servers', { namespaced: namespaced_server })

      expect { supervisor.stop_all }.not_to raise_error
      expect(namespaced_server[0]).to have_received(:stop).once
      expect(namespaced_server[1]).to have_received(:join).once
    end
  end
end
