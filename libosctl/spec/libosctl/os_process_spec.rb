# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/exceptions'
require 'libosctl/id_map'
require 'libosctl/os_process'

RSpec.describe OsCtl::Lib::OsProcess do
  def build_process(root, pid)
    process = described_class.new(pid, parse_stat: false, parse_status: false)
    process.instance_variable_set(:@path, File.join(root, pid.to_s))
    process
  end

  def write_status_files(root, pid, cgroup:)
    stat_fields = %w[
      S 10 20
      0 0 0 0 0 0 0 0
      200 100
      0 0 0
      5 3 0
      50 4096 2
    ]

    write_proc_file(root, pid, 'stat', "#{pid} (ruby) #{stat_fields.join(' ')}\n")
    write_proc_file(root, pid, 'status', <<~STATUS)
      Name:	ruby
      Uid:	1000	1001	1002	1003
      Gid:	2000	2001	2002	2003
      NSpid:	#{pid}	321
    STATUS
    write_proc_file(root, pid, 'uid_map', "0 1000 10\n")
    write_proc_file(root, pid, 'gid_map', "0 2000 10\n")
    write_proc_file(root, pid, 'cgroup', cgroup)
    write_proc_file(root, pid, 'cmdline', "ruby\0script.rb\0")
  end

  it 'parses stat/status data and derives container identity and namespace ids' do
    with_tmpdir do |dir|
      write_status_files(
        dir,
        123,
        cgroup: "0::/osctl/pool.tank/ct.ct1/user-owned\n1:name=systemd:/user.slice\n"
      )

      allow(described_class).to receive(:system_start_time).and_return(Time.at(1000))

      process = build_process(dir, 123)
      process.parse

      expect(process.pid).to eq(123)
      expect(process.ppid).to eq(10)
      expect(process.pgrp).to eq(20)
      expect(process.state).to eq('S')
      expect(process.name).to eq('ruby')
      expect(process.nspid).to eq([123, 321])
      expect(process.ct_pid).to eq(321)
      expect(process.vmsize).to eq(4096)
      expect(process.rss).to eq(2 * described_class::PAGE_SIZE)
      expect(process.nice).to eq(5)
      expect(process.num_threads).to eq(3)
      expect(process.user_time).to eq(200 / described_class::TICS_PER_SECOND)
      expect(process.sys_time).to eq(100 / described_class::TICS_PER_SECOND)
      expect(process.start_time).to eq(Time.at(1000) + (50 / described_class::TICS_PER_SECOND))
      expect(process.ct_id).to eq(%w[tank ct1])
      expect(process.ct_ruid).to eq(0)
      expect(process.ct_euid).to eq(1)
      expect(process.ct_rgid).to eq(0)
      expect(process.ct_egid).to eq(1)
      expect(process.cmdline).to eq('ruby script.rb')
    end
  end

  it 'returns nil when the process is not inside a container and flushes caches' do
    with_tmpdir do |dir|
      write_status_files(dir, 123, cgroup: "0::/user.slice\n")
      allow(described_class).to receive(:system_start_time).and_return(Time.at(1000))

      process = build_process(dir, 123)
      process.parse

      expect(process.ct_id).to be_nil
      expect(process.cmdline).to eq('ruby script.rb')

      File.write(File.join(dir, '123', 'cmdline'), "ruby\0other.rb\0")
      File.write(File.join(dir, '123', 'cgroup'), "0::/osctl/pool.tank/ct.ct2/user-owned\n")

      process.flush

      expect(process.cmdline).to eq('ruby other.rb')
      expect(process.ct_id).to eq(%w[tank ct2])
    end
  end

  it 'builds parent and grandparent processes through the constructor' do
    with_tmpdir do |dir|
      write_status_files(dir, 123, cgroup: "0::/user.slice\n")
      allow(described_class).to receive(:system_start_time).and_return(Time.at(1000))

      process = build_process(dir, 123)
      process.parse

      parent = instance_double(described_class)
      allow(described_class).to receive(:new).with(10, parse_stat: false, parse_status: false).and_return(parent)
      allow(parent).to receive(:parent).and_return(:grandparent)

      expect(process.parent).to eq(parent)
      expect(process.grandparent).to eq(:grandparent)
    end
  end

  it 'raises OsProcessNotFound when proc files disappear' do
    with_tmpdir do |dir|
      process = build_process(dir, 123)

      expect do
        process.parse
      end.to raise_error(OsCtl::Lib::Exceptions::OsProcessNotFound, 'process 123 not found')
    end
  end
end
