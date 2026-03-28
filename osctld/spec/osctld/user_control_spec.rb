# frozen_string_literal: true

require 'osctld/user_control'

RSpec.describe OsCtld::UserControl do
  it 'stops all user control servers through the supervisor' do
    stub_const('OsCtld::UserControl::Supervisor', Class.new do
      def self.stop_all; end
    end)
    allow(OsCtld::UserControl::Supervisor).to receive(:stop_all)

    described_class.stop

    expect(OsCtld::UserControl::Supervisor).to have_received(:stop_all).once
  end
end
