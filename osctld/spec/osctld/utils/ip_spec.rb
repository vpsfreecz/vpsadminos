# frozen_string_literal: true

require 'osctld/utils/ip'

RSpec.describe OsCtld::Utils::Ip do
  let(:host) do
    Class.new do
      include OsCtld::Utils::Ip

      attr_reader :calls

      def initialize
        @calls = []
      end

      def syscmd(cmd, opts)
        calls << [cmd, opts]
        :ok
      end
    end.new
  end

  it 'builds ip commands for the requested protocol family' do
    expect(host.ip(4, %w[addr show], valid_rcs: [0])).to eq(:ok)
    expect(host.ip(6, %w[route show], valid_rcs: [0])).to eq(:ok)
    expect(host.tc(%w[qdisc show], valid_rcs: [0])).to eq(:ok)

    expect(host.calls).to eq(
      [
        ['ip -4 addr show', { valid_rcs: [0] }],
        ['ip -6 route show', { valid_rcs: [0] }],
        ['tc qdisc show', { valid_rcs: [0] }]
      ]
    )
  end
end
