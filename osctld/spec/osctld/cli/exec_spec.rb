# frozen_string_literal: true

module OsCtld
  module Cli; end
end

require 'osctld/cli/exec'

RSpec.describe OsCtld::Cli::Exec do
  it 'prints usage and exits on invalid argv' do
    with_argv('settings.json') do
      expect do
        described_class.run
      end.to raise_error(SystemExit)
    end
  end

  it 'loads the settings file and execs the requested command' do
    with_tmpdir do |tmpdir|
      config_path = File.join(tmpdir, 'exec.json')
      File.write(config_path, {
        user: 'alice',
        ugid: 1234,
        homedir: '/home/alice',
        cgroup_path: '/osctl/pool.tank/ct.ct1',
        syslogns_pid: 55,
        prlimits: { nofile: { soft: 1024, hard: 2048 } }
      }.to_json)

      stub_const('OsCtld::CGroup', Class.new do
        def self.init; end
      end)
      stub_const('OsCtld::SwitchUser', Class.new do
        def self.apply_prlimits(_pid, _prlimits); end

        def self.switch_to(*, **); end
      end)
      allow(OsCtld::CGroup).to receive(:init)
      allow(OsCtld::SwitchUser).to receive(:apply_prlimits)
      allow(OsCtld::SwitchUser).to receive(:switch_to)
      allow(OsCtl::Lib::Logger).to receive(:setup)
      allow(Process).to receive(:exec)

      with_argv(config_path, '--', 'echo', 'hello') do
        described_class.run
      end

      expect(OsCtl::Lib::Logger).to have_received(:setup).with(:none)
      expect(OsCtld::CGroup).to have_received(:init)
      expect(OsCtld::SwitchUser).to have_received(:apply_prlimits).with(
        Process.pid,
        nofile: { soft: 1024, hard: 2048 }
      )
      expect(OsCtld::SwitchUser).to have_received(:switch_to).with(
        'alice',
        1234,
        '/home/alice',
        '/osctl/pool.tank/ct.ct1',
        syslogns_pid: 55,
        tracingns_pid: nil
      )
      expect(Process).to have_received(:exec).with('echo', 'hello')
    end
  end
end
