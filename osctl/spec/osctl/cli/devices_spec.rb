# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Devices do
  let(:klass) do
    Class.new(OsCtl::Cli::Command) do
      include OsCtl::Cli::Devices
    end
  end

  def cmd(args:, opts: {})
    build_command(klass, args:, opts:)
  end

  it 'validates device type for add' do
    expect do
      cmd(args: %w[ct1 bad 1 2 rwm]).do_device_add(:ct_device_add, id: 'ct1')
    end.to raise_error(GLI::BadCommandLine, 'device type has to be one of: block, char')
  end

  it 'builds the add payload' do
    command = cmd(args: %w[ct1 char 1 2 rwm /dev/null], opts: { inherit: true, parents: true })

    expect(command).to receive(:osctld_fmt).with(
      :ct_device_add,
      cmd_opts: {
        id: 'ct1',
        type: 'char',
        major: '1',
        minor: '2',
        mode: 'rwm',
        dev_name: '/dev/null',
        inherit: true,
        parents: true
      }
    )

    command.do_device_add(:ct_device_add, id: 'ct1')
  end

  [
    [:do_device_delete, :ct_device_delete, { recursive: true }],
    [:do_device_promote, :ct_device_promote, {}],
    [:do_device_inherit, :ct_device_inherit, {}],
    [:do_device_set_inherit, :ct_device_set_inherit, {}],
    [:do_device_unset_inherit, :ct_device_unset_inherit, {}]
  ].each do |method_name, osctld_cmd, extra_opts|
    it "builds the payload for #{method_name}" do
      command = cmd(args: %w[ct1 char 1 2], opts: extra_opts)

      expect(command).to receive(:osctld_fmt).with(
        osctld_cmd,
        cmd_opts: {
          id: 'ct1',
          type: 'char',
          major: '1',
          minor: '2'
        }.merge(extra_opts)
      )

      command.public_send(method_name, osctld_cmd, id: 'ct1')
    end
  end

  it 'builds chmod payloads and supports clearing the mode' do
    command = cmd(args: %w[ct1 char 1 2 -], opts: { parents: true, recursive: true })

    expect(command).to receive(:osctld_fmt).with(
      :ct_device_chmod,
      cmd_opts: {
        id: 'ct1',
        type: 'char',
        major: '1',
        minor: '2',
        mode: '',
        parents: true,
        recursive: true
      }
    )

    command.do_device_chmod(:ct_device_chmod, id: 'ct1')
  end

  it 'replaces devices from stdin json' do
    command = cmd(args: %w[ct1])

    expect(command).to receive(:osctld_fmt).with(
      :ct_device_replace,
      cmd_opts: { id: 'ct1', devices: [{ 'type' => 'char' }] }
    )

    with_stdin(JSON.generate('devices' => [{ 'type' => 'char' }])) do
      command.do_device_replace(:ct_device_replace, id: 'ct1')
    end
  end
end
