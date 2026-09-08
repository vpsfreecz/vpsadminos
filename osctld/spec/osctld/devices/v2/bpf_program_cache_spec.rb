# frozen_string_literal: true

require 'osctld/devices/device'
require 'osctld/devices/mode'
require 'osctld/bpf_fs'
require 'osctld/devices/v2/bpf_link'
require 'osctld/devices/v2/bpf_program'
require 'osctld/devices/v2/bpf_program_cache'

RSpec.describe OsCtld::Devices::V2::BpfProgramCache do
  let(:cache) { described_class.send(:new) }
  let(:dev_a) { OsCtld::Devices::Device.new(:char, 1, 3, 'rwm') }
  let(:dev_b) { OsCtld::Devices::Device.new(:block, 8, 0, 'rw') }

  before do
    OsCtl::Lib::Logger.setup(:none)
    allow(OsCtld::BpfFs).to receive(:list_progs).and_return([])
  end

  it 'hashes devices according to ordering' do
    expect(cache.get_prog_name([dev_a, dev_b])).not_to eq(
      cache.get_prog_name([dev_b, dev_a])
    )
  end

  it 'recreates missing pin directories before attaching programs' do
    calls = []
    prog = instance_double(
      OsCtld::Devices::V2::BpfProgram,
      exist?: false,
      create: nil,
      attached?: false,
      attach: nil
    )

    allow(OsCtld::Devices::V2::BpfProgram).to receive(:new).and_return(prog)
    allow(OsCtld::BpfFs).to receive(:link_pinned?).and_return(false)
    allow(OsCtld::BpfFs).to receive(:setup) { calls << :setup }
    allow(OsCtld::BpfFs).to receive(:add_pool) { |pool| calls << [:add_pool, pool] }

    cache.set('tank', [dev_a], '/sys/fs/cgroup/osctl/pool.tank/ct.testct')

    expect(calls).to eq([:setup, [:add_pool, 'tank']])
  end

  context 'with an inherited public cgroup link' do
    def public_path
      '/sys/fs/cgroup/osctl/pool.tank/ct.testct'
    end

    def private_path
      '/run/osctl/cgroup/osctl/pool.tank/ct.testct'
    end

    def old_name
      cache.get_prog_name([dev_a])
    end

    def old_link
      OsCtld::Devices::V2::BpfLink.new(old_name, 'tank', public_path)
    end

    let(:old_program) do
      instance_double(
        OsCtld::Devices::V2::BpfProgram,
        exist?: true, attached?: false, attach: nil, destroy: nil, detach: nil
      )
    end
    let(:new_program) do
      instance_double(
        OsCtld::Devices::V2::BpfProgram,
        exist?: false, create: nil, attached?: false, attach: nil, replace: nil
      )
    end

    before do
      allow(OsCtld::BpfFs).to receive(:setup)
      allow(OsCtld::BpfFs).to receive(:add_pool)
      allow(OsCtld::BpfFs).to receive(:list_links).with('tank').and_return([old_link.name])
      allow(OsCtld::BpfFs).to receive(:link_pinned?).and_return(true)
      allow(OsCtld::Devices::V2::BpfProgram).to receive(:new).and_return(new_program)
      cache.instance_variable_get(:@programs)[old_name] = old_program
      cache.load_links('tank')
    end

    it 'replaces the inherited link instead of stacking a second policy' do
      cache.set('tank', [dev_b], private_path, prog_name: old_name)

      expect(new_program).to have_received(:replace).with(
        have_attributes(path: old_link.path),
        have_attributes(cgroup_path: private_path)
      )
      expect(new_program).not_to have_received(:attach)
      expect(old_program).to have_received(:destroy)
    end

    it 'keeps an unchanged inherited link without attaching a duplicate' do
      expect(cache.set('tank', [dev_a], private_path, prog_name: old_name)).to eq(old_name)
      expect(old_program).not_to have_received(:attach)
      expect(old_program).not_to have_received(:destroy)
    end

    it 'prunes the inherited pin through the private cgroup alias' do
      cache.prune_cgroup_links(private_path)

      expect(old_program).to have_received(:detach).with(have_attributes(path: old_link.path))
      expect(old_program).to have_received(:destroy)
    end

    it 'replaces the cached link when the caller has no previous program hint' do
      cache.set('tank', [dev_b], private_path)

      expect(new_program).to have_received(:replace).with(
        have_attributes(path: old_link.path),
        have_attributes(cgroup_path: private_path)
      )
      expect(new_program).not_to have_received(:attach)
    end

    it 'does not alias a path with a similar prefix' do
      cache.prune_cgroup_links('/sys/fs/cgroup-other/osctl/pool.tank/ct.testct')

      expect(old_program).not_to have_received(:detach)
      cache.prune_cgroup_links(private_path)
      expect(old_program).to have_received(:detach).with(have_attributes(path: old_link.path))
    end

    it 'keeps an unrelated sibling link when replacing this policy' do
      sibling_path = '/sys/fs/cgroup/osctl/pool.tank/ct.sibling'
      sibling = OsCtld::Devices::V2::BpfLink.new(old_name, 'tank', sibling_path)
      allow(OsCtld::BpfFs).to receive(:list_links).with('tank').and_return([old_link.name, sibling.name])
      cache.load_links('tank')
      cache.set('tank', [dev_b], private_path, prog_name: old_name)

      expect(old_program).not_to have_received(:destroy)
      cache.prune_cgroup_links('/run/osctl/cgroup/osctl/pool.tank/ct.sibling')
      expect(old_program).to have_received(:detach).with(have_attributes(path: sibling.path))
      expect(old_program).to have_received(:destroy)
    end

    it 'retains the cached link if detachment fails' do
      allow(old_program).to receive(:detach).and_raise('detach failed')
      expect { cache.prune_cgroup_links(private_path) }.to raise_error('detach failed')
      expect(old_program).not_to have_received(:destroy)

      allow(old_program).to receive(:detach).and_return(nil)
      cache.prune_cgroup_links(private_path)
      expect(old_program).to have_received(:destroy)
    end

    it 'retains the old link bookkeeping if replacement fails' do
      allow(new_program).to receive(:replace).and_raise('replace failed')
      expect do
        cache.set('tank', [dev_b], private_path, prog_name: old_name)
      end.to raise_error('replace failed')

      cache.prune_cgroup_links(private_path)
      expect(old_program).to have_received(:detach).with(have_attributes(path: old_link.path))
    end
  end
end
