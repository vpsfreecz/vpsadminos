# frozen_string_literal: true

require 'osctld/system_users'

RSpec.describe OsCtld::SystemUsers do
  subject(:system_users) do
    commands = []
    getent_output = ''

    described_class.send(:allocate).tap do |instance|
      instance.send(:init_lock)
      instance.instance_variable_set('@users', {})

      instance.define_singleton_method(:commands) do
        commands
      end

      instance.define_singleton_method(:getent_output=) do |output|
        getent_output = output
      end

      instance.define_singleton_method(:syscmd) do |cmd, valid_rcs: nil|
        commands << [cmd, valid_rcs]
        Struct.new(:output).new(cmd == 'getent passwd' ? getent_output : '')
      end
    end
  end

  before do
    stub_const('OsCtld::UGidRegistry', Class.new do
      def self.<<(uid); end
    end)
    allow(OsCtld::UGidRegistry).to receive(:<<)
  end

  it 'loads only osctl-tagged users from getent output' do
    system_users.getent_output = [
      'alice:x:1000:1000:osctl:/home/alice:/bin/sh',
      'bob:x:1001:1001:not-osctl:/home/bob:/bin/sh'
    ].join("\n")

    system_users.send(:load_users)

    expect(system_users.include?('alice')).to be(true)
    expect(system_users.include?('bob')).to be(false)
    expect(system_users.uid_of('alice')).to eq(1000)
    expect(OsCtld::UGidRegistry).to have_received(:<<).with(1000)
    expect(OsCtld::UGidRegistry).to have_received(:<<).with(1001)
  end

  it 'adds and removes users while keeping the cache in sync' do
    system_users.add('alice', 1000, '/home/alice')
    expect(system_users.include?('alice')).to be(true)
    expect(system_users.uid_of('alice')).to eq(1000)

    system_users.remove('alice')

    expect(system_users.include?('alice')).to be(false)
    expect(system_users.commands).to include(['groupadd -g 1000 alice', nil])
    expect(system_users.commands).to include(
      ['useradd -u 1000 -g 1000 -d /home/alice -c osctl alice', nil]
    )
    expect(system_users.commands).to include(['userdel -f alice', nil])
    expect(system_users.commands).to include(['groupdel alice', [6]])
  end
end
