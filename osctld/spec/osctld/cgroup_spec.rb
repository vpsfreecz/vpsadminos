# frozen_string_literal: true

require 'spec_helper'
require 'osctld/cgroup'

RSpec.describe OsCtld::CGroup do
  around do |example|
    original_fs = described_class.instance_variable_get(:@fs)
    original_version = described_class.instance_variable_get(:@version)

    example.run
  ensure
    described_class.instance_variable_set(:@fs, original_fs)
    described_class.instance_variable_set(:@version, original_version)
  end

  def reset_cgroup(version:)
    described_class.instance_variable_set(:@version, version)
    described_class.instance_variable_set(:@fs, nil)
  end

  it 'prefers the runstate cgroupfs bind mount on cgroup v2' do
    Dir.mktmpdir do |dir|
      runstate_fs = File.join(dir, 'runstate')
      default_fs = File.join(dir, 'default')

      FileUtils.mkdir_p(runstate_fs)
      FileUtils.mkdir_p(default_fs)
      FileUtils.touch(File.join(runstate_fs, 'cgroup.procs'))
      FileUtils.touch(File.join(default_fs, 'cgroup.procs'))

      stub_const("#{described_class}::RUNSTATE_FS", runstate_fs)
      stub_const("#{described_class}::DEFAULT_FS", default_fs)
      reset_cgroup(version: 2)

      expect(described_class.fs).to eq(runstate_fs)
      expect(described_class.abs_cgroup_path(nil, 'osctl')).to eq(
        File.join(runstate_fs, 'osctl')
      )
    end
  end

  it 'falls back to the default cgroupfs path when runstate is unavailable' do
    Dir.mktmpdir do |dir|
      runstate_fs = File.join(dir, 'missing')
      default_fs = File.join(dir, 'default')

      FileUtils.mkdir_p(default_fs)
      FileUtils.touch(File.join(default_fs, 'cgroup.procs'))

      stub_const("#{described_class}::RUNSTATE_FS", runstate_fs)
      stub_const("#{described_class}::DEFAULT_FS", default_fs)
      reset_cgroup(version: 2)

      expect(described_class.fs).to eq(default_fs)
    end
  end
end
