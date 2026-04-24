# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/send_receive'
require 'osctld/send_receive/command'
require 'osctld/utils/receive'
require 'osctld/send_receive/commands/receive_cancel'
require 'osctld/send_receive/commands/receive_transfer'

RSpec.describe OsCtld::SendReceive::Commands::Transfer do
  describe 'command behavior' do
    def build_send_log
      send_log_opts_class = Struct.new(:key_name, :protocol_version, keyword_init: true)

      Struct.new(:state, :snapshots, :opts, keyword_init: true) do
        def can_receive_continue?(stage)
          stage == :transfer
        end

        def protocol_version
          opts.protocol_version
        end
      end.new(
        state: :incremental,
        snapshots: [['tank/ct1', 'snap1']],
        opts: send_log_opts_class.new(
          key_name: 'auth-key',
          protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION
        )
      )
    end

    def build_ct(pool, send_log)
      mount_manager_class = Struct.new(:shared_dir, :prune_calls) do
        def prune
          self.prune_calls += 1
        end
      end
      shared_dir_class = Struct.new(:remove_calls) do
        def remove
          self.remove_calls += 1
        end
      end
      apparmor_class = Struct.new(:destroy_namespace_calls, :unload_profile_calls) do
        def destroy_namespace
          self.destroy_namespace_calls += 1
        end

        def unload_profile
          self.unload_profile_calls += 1
        end
      end

      Class.new do
        attr_reader :pool, :id, :send_log, :save_config_calls, :stopped_calls, :mounts, :apparmor
        attr_accessor :state, :closed_send_log

        define_method(:initialize) do |ct_pool, ct_send_log|
          @pool = ct_pool
          @send_log = ct_send_log
          @id = 'ct1'
          @state = :staged
          @closed_send_log = false
          @save_config_calls = 0
          @stopped_calls = 0
          @unmount_calls = 0
          @clear_start_menu_calls = 0
          @mounts = mount_manager_class.new(shared_dir_class.new(0), 0)
          @apparmor = apparmor_class.new(0, 0)
        end

        def manipulate(_cmd, block:, &)
          yield
        end

        def exclusively(&block)
          block.call
        end

        def state=(value)
          if state == :staged
            case value
            when :complete
              @state = :stopped
              save_config
              return
            when :running
              @state = :running
              save_config
              return
            end
          end

          @state = value
        end

        def save_config
          @save_config_calls += 1
        end

        def stopped
          @stopped_calls += 1
        end

        attr_reader :unmount_calls, :clear_start_menu_calls

        def unmount(force: false)
          @unmount_calls += 1 if force
        end

        def clear_start_menu
          @clear_start_menu_calls += 1
        end

        def close_send_log
          @closed_send_log = true
          save_config
        end
      end.new(pool, send_log)
    end

    let(:pool) do
      Struct.new(:name, keyword_init: true) do
        def active?
          true
        end
      end.new(name: 'tank')
    end
    let(:send_log) { build_send_log }
    let(:ct) { build_ct(pool, send_log) }
    let(:command) do
      described_class.new(
        {
          token: 'abc',
          key_pool: 'tank',
          key_name: 'rx',
          start: start_container,
          protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION
        },
        {}
      )
    end
    let(:start_container) { false }

    before do
      stub_const('OsCtld::SendReceive::Tokens', Class.new do
        def self.find_container(_token); end
      end)
      stub_const('OsCtld::Commands::Container::Start', Class.new)
      stub_const('OsCtld::AppArmor', Class.new do
        def self.enabled?; end
      end)
      stub_const('OsCtld::Console', Class.new do
        def self.remove(_ct); end
      end)
      allow(OsCtld::SendReceive::Tokens).to receive(:find_container)
        .with('abc')
        .and_return(ct)
      allow(OsCtld::Console).to receive(:remove)
      allow(OsCtld::AppArmor).to receive(:enabled?).and_return(true)
      allow(command).to receive_messages(
        check_auth_pubkey: true,
        call_cmd!: { status: true, output: nil },
        remove_accounting_cgroups: nil
      )
      allow(OsCtld::SendReceive).to receive(:stopped_using_key)
    end

    it 'finishes a staged transfer without start as a stopped container' do
      expect(command.execute).to eq(status: true, output: nil)

      expect(ct.state).to eq(:stopped)
      expect(send_log.state).to eq(:transfer)
      expect(send_log.snapshots).to eq([['tank/ct1', 'snap1']])
      expect(ct.save_config_calls).to eq(2)
      expect(OsCtld::SendReceive).not_to have_received(:stopped_using_key)
      expect(ct.closed_send_log).to be(false)
    end

    it 'keeps the transfer open after starting the container' do
      events = []

      allow(command).to receive(:call_cmd!) do |klass, **kwargs|
        events << [:start, klass, kwargs]
        { status: true, output: nil }
      end

      command_with_start = described_class.new(
        {
          token: 'abc',
          key_pool: 'tank',
          key_name: 'rx',
          start: true,
          protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION
        },
        {}
      )
      allow(command_with_start).to receive(:check_auth_pubkey).and_return(true)
      allow(command_with_start).to receive(:remove_accounting_cgroups)
      allow(command_with_start).to receive(:call_cmd!) do |klass, **kwargs|
        events << [:start, klass, kwargs]
        { status: true, output: nil }
      end

      command_with_start.execute

      expect(events).to eq(
        [
          [
            :start,
            OsCtld::Commands::Container::Start,
            { id: 'ct1', pool: 'tank', force: true }
          ]
        ]
      )
      expect(send_log.state).to eq(:transfer)
      expect(ct.closed_send_log).to be(false)
    end

    it 'rolls the target back to staged when start fails' do
      command_with_start = described_class.new(
        {
          token: 'abc',
          key_pool: 'tank',
          key_name: 'rx',
          start: true,
          protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION
        },
        {}
      )
      allow(command_with_start).to receive(:check_auth_pubkey).and_return(true)
      allow(command_with_start).to receive(:remove_accounting_cgroups)
      allow(command_with_start).to receive(:call_cmd!)
        .and_raise(OsCtld::CommandFailed, 'start failed')
      allow(OsCtld::SendReceive).to receive(:stopped_using_key)

      expect do
        command_with_start.execute
      end.to raise_error(OsCtld::CommandFailed, 'start failed')

      expect(ct.state).to eq(:staged)
      expect(ct.stopped_calls).to eq(1)
      expect(ct.unmount_calls).to eq(1)
      expect(ct.clear_start_menu_calls).to eq(1)
      expect(ct.mounts.shared_dir.remove_calls).to eq(1)
      expect(ct.mounts.prune_calls).to eq(1)
      expect(ct.apparmor.destroy_namespace_calls).to eq(1)
      expect(ct.apparmor.unload_profile_calls).to eq(1)
      expect(command_with_start).to have_received(:remove_accounting_cgroups).with(ct)
      expect(OsCtld::Console).to have_received(:remove).with(ct)
      expect(send_log.state).to eq(:incremental)
      expect(send_log.snapshots).to eq([['tank/ct1', 'snap1']])
      expect(OsCtld::SendReceive).not_to have_received(:stopped_using_key)
      expect(ct.closed_send_log).to be(false)
    end

    it 'rejects containers that cannot be found' do
      allow(OsCtld::SendReceive::Tokens).to receive(:find_container)
        .with('abc')
        .and_return(nil)

      expect { command.execute }.to raise_error(OsCtld::CommandFailed, 'container not found')
    end

    it 'rejects inactive target pools' do
      allow(pool).to receive(:active?).and_return(false)

      expect { command.execute }.to raise_error(OsCtld::CommandFailed, 'the pool is disabled')
    end

    it 'rejects invalid send sequences and authentication key mismatches' do
      allow(ct.send_log).to receive(:can_receive_continue?)
        .with(:transfer)
        .and_return(false)

      expect { command.execute }.to raise_error(OsCtld::CommandFailed, 'invalid send sequence')

      allow(ct.send_log).to receive(:can_receive_continue?)
        .with(:transfer)
        .and_return(true)
      allow(command).to receive(:check_auth_pubkey).and_return(false)

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'authentication key mismatch')
    end

    it 'rejects send-log protocol mismatches' do
      send_log.opts.protocol_version = OsCtld::SendReceive::PROTOCOL_VERSION - 1

      expect do
        command.base_execute
      end.to raise_error(OsCtld::CommandFailed, %r{send/receive protocol version mismatch})
    end
  end

  describe OsCtld::SendReceive::Commands::Cleanup do
    def build_send_log
      send_log_opts_class = Struct.new(:key_name, :protocol_version, keyword_init: true)

      Struct.new(:state, :snapshots, :opts, keyword_init: true) do
        def can_receive_continue?(stage)
          stage == :cleanup && %i[transfer cleanup].include?(state)
        end

        def protocol_version
          opts.protocol_version
        end
      end.new(
        state: :transfer,
        snapshots: [['tank/ct1', 'snap1']],
        opts: send_log_opts_class.new(
          key_name: 'auth-key',
          protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION
        )
      )
    end

    def build_ct(pool, send_log)
      Class.new do
        attr_reader :pool, :id, :send_log, :save_config_calls
        attr_accessor :closed_send_log

        def initialize(pool, send_log)
          @pool = pool
          @send_log = send_log
          @id = 'ct1'
          @closed_send_log = false
          @save_config_calls = 0
        end

        def manipulate(_cmd, block:, &)
          yield
        end

        def exclusively(&block)
          block.call
        end

        def save_config
          @save_config_calls += 1
        end

        def close_send_log
          @closed_send_log = true
          save_config
        end
      end.new(pool, send_log)
    end

    let(:pool) do
      Struct.new(:name, keyword_init: true) do
        def active?
          true
        end
      end.new(name: 'tank')
    end
    let(:send_log) { build_send_log }
    let(:ct) { build_ct(pool, send_log) }
    let(:command) do
      described_class.new(
        {
          token: 'abc',
          key_pool: 'tank',
          key_name: 'rx',
          start: start_container,
          protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION
        },
        {}
      )
    end
    let(:start_container) { false }

    before do
      stub_const('OsCtld::SendReceive::Tokens', Class.new do
        def self.find_container(_token); end
      end)
      stub_const('OsCtld::Commands::Container::Start', Class.new)
      allow(OsCtld::SendReceive::Tokens).to receive(:find_container)
        .with('abc')
        .and_return(ct)
      allow(command).to receive_messages(
        check_auth_pubkey: true,
        zfs: nil
      )
      allow(OsCtld::SendReceive).to receive(:stopped_using_key)
    end

    it 'destroys transfer snapshots, releases the key, and closes the send log' do
      expect(command.execute).to eq(status: true, output: nil)

      expect(send_log.state).to eq(:cleanup)
      expect(command).to have_received(:zfs).with(:destroy, nil, 'tank/ct1@snap1', valid_rcs: [1])
      expect(ct.save_config_calls).to eq(2)
      expect(OsCtld::SendReceive).to have_received(:stopped_using_key).with(pool, 'auth-key')
      expect(ct.closed_send_log).to be(true)
    end

    it 'keeps cleanup retryable when snapshot destruction fails' do
      allow(command).to receive(:zfs)
        .with(:destroy, nil, 'tank/ct1@snap1', valid_rcs: [1])
        .and_raise(RuntimeError, 'destroy failed')

      expect do
        command.execute
      end.to raise_error(RuntimeError, 'destroy failed')

      expect(send_log.state).to eq(:cleanup)
      expect(ct.closed_send_log).to be(false)
      expect(OsCtld::SendReceive).not_to have_received(:stopped_using_key)
    end

    it 'rejects invalid send sequences and authentication key mismatches' do
      allow(ct.send_log).to receive(:can_receive_continue?)
        .with(:cleanup)
        .and_return(false)

      expect { command.execute }.to raise_error(OsCtld::CommandFailed, 'invalid send sequence')

      allow(ct.send_log).to receive(:can_receive_continue?)
        .with(:cleanup)
        .and_return(true)
      allow(command).to receive(:check_auth_pubkey).and_return(false)

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'authentication key mismatch')
    end
  end
end
