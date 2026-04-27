# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Send do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'refuses to overwrite existing key files unless forced' do
    client = FakeClientHelpers::ClientDouble.new(
      cmd_data: {
        send_key_path: [{ public_key: '/tmp/pub', private_key: '/tmp/key' }]
      }
    )
    stub_osctld_client(client)
    command = cmd(gopts: { pool: 'tank' })
    allow(File).to receive(:exist?).with('/tmp/pub').and_return(true)
    allow(File).to receive(:exist?).with('/tmp/key').and_return(false)

    expect { command.key_gen }.to raise_error(/already exists/)
  end

  it 'prints key paths and validates the requested key kind' do
    command = cmd(args: ['public'], gopts: { pool: 'tank' })
    allow(command).to receive(:osctld_call).and_return(public_key: '/tmp/pub', private_key: '/tmp/key')

    out, = capture_output { command.key_path }
    expect(out).to eq("/tmp/pub\n")

    expect { cmd(args: ['bad']).key_path }.to raise_error(GLI::BadCommandLine, "expected public/private, got 'bad'")
  end

  it 'dispatches send actions through with_progress' do
    {
      config: [:ct_send_config, %w[ct1 user@dst], {}],
      rootfs: [:ct_send_rootfs, ['ct1'], {}],
      sync: [:ct_send_sync, ['ct1'], {}],
      state: [:ct_send_state, ['ct1'], { clone: true }],
      cleanup: [:ct_send_cleanup, ['ct1'], {}],
      cancel: [:ct_send_cancel, ['ct1'], { force: true, local: true }],
      now: [:ct_send_now, %w[ct1 user@dst], { clone: true }]
    }.each do |method_name, (osctld_cmd, args, opts)|
      command = cmd(args:, opts:, gopts: { pool: 'tank' })
      expect(command).to receive(:with_progress).with(osctld_cmd, hash_including(pool: 'tank', id: 'ct1'))
      command.public_send(method_name)
    end
  end
end
