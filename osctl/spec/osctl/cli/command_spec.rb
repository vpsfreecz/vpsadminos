# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Command do
  subject(:command) { build_command(described_class, opts:, gopts:, args:) }

  let(:args) { [] }
  let(:opts) { {} }
  let(:gopts) { {} }

  describe '.run' do
    let(:klass) do
      Class.new(described_class) do
        class << self
          attr_reader :instances
        end

        @instances = []

        def initialize(*)
          super
          self.class.instances << self
        end

        def execute(arg)
          @executed = arg
        end

        attr_reader :executed
      end
    end

    it 'instantiates the command and invokes the chosen method' do
      with_program_name('osctl') do
        with_argv(%w[pool ls]) do
          described_class.run(klass, :execute, ['value']).call({}, {}, [])
        end
      end

      expect(klass.instances.last.executed).to eq('value')
    end
  end

  it 'passes cli metadata through osctld_call when missing' do
    client = FakeClientHelpers::ClientDouble.new(cmd_data: { ct_list: ['ok'] })
    stub_osctld_client(client)

    with_program_name('osctl') do
      with_argv(%w[ct ls]) do
        expect(command.osctld_call(:ct_list)).to eq('ok')
      end
    end

    expect(client.calls).to include([:cmd_data!, :ct_list, { cli: 'osctl ct ls' }])
    expect(client).to be_closed
  end

  it 'preserves an explicit cli option in osctld_resp' do
    client = FakeClientHelpers::ClientDouble.new(
      cmd_responses: { ct_show: [client_response(status: true, response: { id: 'ct1' })] }
    )
    stub_osctld_client(client)

    resp = command.osctld_resp(:ct_show, id: 'ct1', cli: 'custom cli')

    expect(resp.data).to eq(id: 'ct1')
    expect(client.calls).to include([:cmd_response, :ct_show, { id: 'ct1', cli: 'custom cli' }])
    expect(client).to be_closed
  end

  it 'prints string results directly from osctld_fmt' do
    allow(command).to receive(:osctld_call).and_return('ready')

    out, err = capture_output { command.osctld_fmt(:self_activate) }

    expect(out).to eq("ready\n")
    expect(err).to eq('')
  end

  it 'formats structured results through OutputFormatter in text mode' do
    data = [{ id: 'ct1' }]
    allow(command).to receive(:osctld_call).and_return(data)
    allow(OsCtl::Lib::Cli::OutputFormatter).to receive(:print)

    command.osctld_fmt(:ct_list, fmt_opts: { layout: :columns })

    expect(OsCtl::Lib::Cli::OutputFormatter).to have_received(:print).with(data, layout: :columns)
  end

  it 'suppresses default progress output in quiet mode' do
    quiet_command = build_command(described_class, gopts: { quiet: true })
    allow(quiet_command).to receive(:osctld_call) do |_cmd, **_opts, &block|
      block.call('working')
      'done'
    end

    out, = capture_output { quiet_command.osctld_fmt(:ct_stop) }

    expect(out).to eq("done\n")
  end

  it 'uses an explicit block instead of the default progress printer' do
    progress = []
    allow(command).to receive(:osctld_call) do |_cmd, **_opts, &block|
      block.call('working')
      'done'
    end

    out, = capture_output do
      command.osctld_fmt(:ct_stop) { |msg| progress << msg }
    end

    expect(progress).to eq(['working'])
    expect(out).to eq("done\n")
  end

  it 'prints json when requested' do
    json_command = build_command(described_class, gopts: { json: true })

    out, = capture_output do
      json_command.format_output({ id: 'ct1' })
    end

    expect(JSON.parse(out)).to eq('id' => 'ct1')
  end
end
