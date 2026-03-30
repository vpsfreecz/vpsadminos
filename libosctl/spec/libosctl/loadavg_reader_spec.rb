# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/loadavg_reader'

RSpec.describe OsCtl::Lib::LoadAvgReader do
  it 'maps init pids to cgroup namespaces and returns keyed load averages' do
    with_tmpdir do |dir|
      file = File.join(dir, 'loadavg')
      File.write(file, <<~LOADAVG)
        11 0.10 0.20 0.30 1/2
        99 9.99 9.99 9.99 9/9
        malformed line
      LOADAVG

      stub_const("#{described_class}::FILE", file)

      allow(File).to receive(:readlink).and_wrap_original do |method, path, *args|
        case path
        when '/proc/101/ns/cgroup'
          'cgroup:[11]'
        when '/proc/202/ns/cgroup'
          raise Errno::ENOENT, path
        else
          method.call(path, *args)
        end
      end

      result = described_class.read_for(
        [
          { pool: 'tank', id: 'ct1', init_pid: 101 },
          { pool: 'tank', id: 'ct2', init_pid: nil },
          { pool: 'fast', id: 'ct3', init_pid: 202 }
        ]
      )

      expect(result.keys).to eq(['tank:ct1'])
      expect(result['tank:ct1']).to have_attributes(
        pool_name: 'tank',
        ctid: 'ct1',
        avg: { 1 => 0.10, 5 => 0.20, 15 => 0.30 },
        runnable: 1,
        total: 2
      )
    end
  end

  it 'stops early when the block asks it to' do
    with_tmpdir do |dir|
      file = File.join(dir, 'loadavg')
      File.write(file, <<~LOADAVG)
        11 0.10 0.20 0.30 1/2
        12 0.40 0.50 0.60 3/4
      LOADAVG

      stub_const("#{described_class}::FILE", file)

      allow(File).to receive(:readlink).and_wrap_original do |method, path, *args|
        case path
        when '/proc/101/ns/cgroup'
          'cgroup:[11]'
        when '/proc/102/ns/cgroup'
          'cgroup:[12]'
        else
          method.call(path, *args)
        end
      end

      yielded = []

      described_class.new.read(
        [
          { pool: 'tank', id: 'ct1', init_pid: 101 },
          { pool: 'tank', id: 'ct2', init_pid: 102 }
        ]
      ) do |lavg|
        yielded << lavg.ident
        :stop
      end

      expect(yielded).to eq(['tank:ct1'])
    end
  end

  it 'ignores missing loadavg files' do
    stub_const("#{described_class}::FILE", '/definitely/missing')

    expect(described_class.read_for([])).to eq({})
  end
end
