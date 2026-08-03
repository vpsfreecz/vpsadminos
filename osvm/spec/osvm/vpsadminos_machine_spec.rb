# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::VpsadminosMachine do
  def stub_booted_machine(machine)
    allow(machine).to receive_messages(
      running?: true,
      wait_for_boot: machine,
      monotonic_now: 100.0
    )
  end

  it 'parses osctl json output' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:succeeds).with('osctl -j pool ls').and_return([0, '{"state":"active"}'])

      expect(machine.osctl_json('pool ls')).to eq('state' => 'active')
    end
  end

  it 'waits for zpools by delegating to wait_until_succeeds' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:wait_until_succeeds).and_return([0, ''])

      expect(machine.wait_for_zpool('tank', timeout: 12)).to eq(machine)
      expect(machine).to have_received(:wait_until_succeeds).with('zpool list tank', timeout: 12)
    end
  end

  it 'waits for osctl pools to become active' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      stub_booted_machine(machine)
      allow(machine).to receive(:execute).and_return([0, "importing\n"], [0, "active\n"])
      allow(machine).to receive(:sleep)

      expect(machine.wait_for_osctl_pool('tank', timeout: 120)).to eq(machine)
      expect(machine).to have_received(:execute).with(
        'osctl pool show -H -o state tank',
        timeout: 60,
        deadline: 220.0,
        timeout_message: kind_of(String)
      ).twice
    end
  end

  it 'starts stopped VMs before waiting for osctl pools' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive_messages(
        running?: false,
        wait_for_boot: machine,
        execute: [0, "active\n"],
        monotonic_now: 100.0
      )
      allow(machine).to receive(:start)

      expect(machine.wait_for_osctl_pool('tank', timeout: 20)).to eq(machine)
      expect(machine).to have_received(:start).with(
        deadline: 120.0,
        timeout_message: 'Timeout occurred while waiting for pool "tank" to become active'
      )
      expect(machine).to have_received(:wait_for_boot).with(
        timeout: 20.0,
        deadline: 120.0,
        timeout_message: 'Timeout occurred while waiting for pool "tank" to become active'
      )
    end
  end

  it 'retries timed out osctl pool probes' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      stub_booted_machine(machine)
      calls = 0
      allow(machine).to receive(:execute) do |*, **|
        calls += 1
        raise OsVm::TimeoutError, 'timed out' if calls == 1

        [0, "active\n"]
      end
      allow(machine).to receive(:sleep)

      expect(machine.wait_for_osctl_pool('tank', timeout: 120)).to eq(machine)
      expect(machine).to have_received(:execute).with(
        'osctl pool show -H -o state tank',
        timeout: 60,
        deadline: 220.0,
        timeout_message: kind_of(String)
      ).twice
    end
  end

  it 'times out while waiting for an osctl pool to become active' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      stub_booted_machine(machine)
      allow(machine).to receive(:execute).and_return([0, "importing\n"])

      expect do
        machine.wait_for_osctl_pool('tank', timeout: 0)
      end.to raise_error(OsVm::TimeoutError, /waiting for pool "tank" to become active/)
    end
  end

  it 'keeps pool diagnostics when the real shell protocol consumes the deadline' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      shell = machine.send(:current_shell)
      wait_timeouts = []
      readable_calls = 0
      io = instance_double(IO, closed?: false, close: nil, write: nil)
      allow(io).to receive(:wait_readable) do |timeout|
        wait_timeouts << timeout
        readable_calls += 1
        next true if readable_calls <= 2

        sleep(timeout)
        false
      end
      allow(io).to receive(:read_nonblock).and_return(
        "#{Base64.strict_encode64("importing\n")}\n",
        "0\n"
      )
      allow(machine).to receive(:sleep_with_deadline)
      machine.instance_variable_set(:@running, true)
      shell.instance_variable_set(:@up, true)
      shell.instance_variable_set(:@io, io)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect do
        machine.wait_for_osctl_pool('tank', timeout: 0.1, poll_timeout: 0.1)
      end.to raise_error(
        OsVm::TimeoutError,
        /last state: "importing".*last error:/
      )

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      expect(elapsed).to be < 0.5
      expect(wait_timeouts).not_to be_empty
      expect(wait_timeouts).to all(be_between(0, 0.1).exclusive)
    end
  end

  it 'never retries a pool command after its shell protocol deadline' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      shell = machine.send(:current_shell)
      shell_log = shell.send(:log)
      writes = []
      io = instance_double(IO, closed?: false, close: nil)
      allow(shell_log).to receive(:execute_end).and_call_original
      allow(io).to receive(:write) { |data| writes << data }
      allow(io).to receive(:wait_readable).and_raise(
        OsVm::TimeoutError,
        'shell protocol deadline expired'
      )
      machine.instance_variable_set(:@running, true)
      shell.instance_variable_set(:@up, true)
      shell.instance_variable_set(:@io, io)

      expect do
        machine.wait_for_osctl_pool('tank', timeout: 1, poll_timeout: 0.05)
      end.to raise_error(
        OsVm::UnrecoverableTimeoutError,
        /waiting for pool "tank" to become active.*last error:/
      )

      pool_commands = writes.grep(/osctl/)
      expect(pool_commands.length).to eq(1)
      expect(pool_commands.first).to include(
        'osctl\\ pool\\ show\\ -H\\ -o\\ state\\ tank'
      )
      expect(io).to have_received(:close).once
      expect(shell_log).to have_received(:execute_end).once
    end
  end

  it 'waits for osctl containers to reach the requested state' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:wait_until_succeeds).and_return([0, "stopped\n"], [0, "running\n"])
      allow(machine).to receive(:sleep)

      expect(machine.wait_for_osctl_container('ct1')).to eq(machine)
    end
  end

  it 'times out while waiting for an osctl container state' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:wait_until_succeeds).and_return([0, "stopped\n"])

      expect do
        machine.wait_for_osctl_container('ct1', timeout: 0)
      end.to raise_error(OsVm::TimeoutError, /waiting for container "ct1" to become running/)
    end
  end

  it 'waits for containers to become online through osctl ct exec' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:wait_until_succeeds).and_return([0, ''])

      expect(machine.wait_until_container_online('ct1', timeout: 12)).to eq(machine)
      expect(machine).to have_received(:wait_until_succeeds).with(
        "osctl ct exec ct1 sh -c 'ping -c 1 check-online.vpsadminos.org || curl --head https://check-online.vpsadminos.org || wget -O - https://check-online.vpsadminos.org || getent hosts check-online.vpsadminos.org'",
        timeout: 12
      )
    end
  end

  it 'includes squashfs boot media only when configured' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      no_media_machine = build_vpsadminos_machine(
        dir:,
        config: build_machine_config(
          {
            'bootMode' => 'firmware',
            'bootOrder' => 'dc',
            'kernel' => nil,
            'initrd' => nil,
            'toplevel' => nil,
            'squashfs' => nil,
            'networks' => [{ 'type' => 'user', 'mac' => '52:54:00:00:00:20' }]
          }
        )
      )

      expect(machine.send(:qemu_boot_media_options)).to include(
        '-drive',
        'index=0,id=drive1,file=/images/system.squashfs,readonly=on,media=cdrom,format=raw,if=virtio'
      )
      expect(no_media_machine.send(:qemu_boot_media_options)).to eq([])
    end
  end

  it 'builds qemu commands with boot media and shared options' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:, config: build_machine_config('iso' => '/images/install.iso'))

      command = machine.send(:qemu_command, kernel_params: ['debug'])

      expect(command).to include('/nix/store/qemu/bin/qemu-kvm')
      expect(command).to include('-cdrom', '/images/install.iso')
      expect(command).to include('-drive', 'index=0,id=drive1,file=/images/system.squashfs,readonly=on,media=cdrom,format=raw,if=virtio')
      expect(command.grep(/path=.*shell\.sock/).first).not_to be_nil
      expect(command.grep(/tag=vmSharedDir/).first).not_to be_nil
    end
  end
end
