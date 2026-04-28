# frozen_string_literal: true

require 'tempfile'

module OsCtld
  module Cli
  end
end

require 'osctld/cli/exec'

RSpec.describe OsCtld::Cli::Exec do
  describe '.insert_lxc_attach_config' do
    it 'inserts the transient config before the attached command separator' do
      cmd = %w[lxc-attach -P /run/lxc -n ct1 -- /bin/sh]

      expect(described_class.insert_lxc_attach_config(cmd, '/tmp/attach.conf')).to eq(
        %w[lxc-attach -P /run/lxc -n ct1 -f /tmp/attach.conf -- /bin/sh]
      )
    end

    it 'appends the transient config when no command separator is present' do
      cmd = %w[lxc-attach -P /run/lxc -n ct1]

      expect(described_class.insert_lxc_attach_config(cmd, '/tmp/attach.conf')).to eq(
        %w[lxc-attach -P /run/lxc -n ct1 -f /tmp/attach.conf]
      )
    end
  end

  describe '.lxc_attach_config_without_prlimits' do
    it 'copies LXC config without prlimit entries' do
      source = Tempfile.create(['ct1', '.conf'])
      source.write(<<~CONFIG)
        lxc.uts.name = ct1
        lxc.prlimit.nofile = 1024:1048576
        lxc.mount.auto = proc:mixed
      CONFIG
      source.close

      config = described_class.lxc_attach_config_without_prlimits(source.path)

      expect(File.read(config.path)).to eq(<<~CONFIG)
        lxc.uts.name = ct1
        lxc.mount.auto = proc:mixed
      CONFIG
    ensure
      [source, config].each do |file|
        next unless file

        path = file.path
        file.close
        File.unlink(path) if path && File.exist?(path)
      end
    end
  end

  describe '.exitstatus' do
    it 'uses the process exit status when the child exits normally' do
      status = instance_double(Process::Status, exited?: true, exitstatus: 7)

      expect(described_class.exitstatus(status)).to eq(7)
    end

    it 'maps a signal termination to a shell-compatible status' do
      status = instance_double(Process::Status, exited?: false, signaled?: true, termsig: 9)

      expect(described_class.exitstatus(status)).to eq(137)
    end
  end
end
