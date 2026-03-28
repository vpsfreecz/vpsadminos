# frozen_string_literal: true

require 'stringio'
require 'osctld/container_control/commands/wall'

RSpec.describe OsCtld::ContainerControl::Commands::Wall do
  describe described_class::Runner do
    def build_runner(status)
      Class.new(described_class) do
        define_method(:initialize) do |wall_status:, **opts|
          @status = wall_status
          super(**opts)
        end

        define_method(:ct_wall) do |_message|
          @status
        end
      end.new(
        wall_status: status,
        pool: 'tank',
        id: 'ct1',
        lxc_home: '/var/lib/lxc',
        user_home: '/home/alice',
        log_file: '/tmp/ct.log',
        stdout: StringIO.new,
        stderr: StringIO.new
      )
    end

    it 'returns ok when wall exits successfully' do
      runner = build_runner(build_wait_status(0))

      expect(runner.execute('hello')).to eq(status: true, output: nil)
    end

    it 'returns a command error when wait status is unavailable' do
      runner = build_runner(1)

      result = runner.execute('hello')

      expect(result).to include(status: false)
      expect(result[:message]).to match(/failed to send message/)
    end
  end
end
