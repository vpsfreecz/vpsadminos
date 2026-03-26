# frozen_string_literal: true

require 'osctld/attributes'
require 'osctld/id_range/allocation_table'
require 'osctld/id_range'

RSpec.describe OsCtld::IdRange do
  def build_range(root:, name: 'default')
    pool = build_fake_pool(root: root)
    prepare_pool_conf_dirs(pool, 'id-range')

    [pool, described_class.new(pool, name, load: false)]
  end

  before do
    allow(File).to receive(:chown).and_return(0)
  end

  it 'persists the configured range metadata' do
    with_tmpdir do |dir|
      _pool, range = build_range(root: dir)

      range.configure(1_000_000, 65_536, 4)

      expect(load_yaml_file(range.config_path)).to eq(
        'start_id' => 1_000_000,
        'block_size' => 65_536,
        'block_count' => 4,
        'allocations' => [],
        'attrs' => {}
      )
    end
  end

  it 'allocates blocks and returns computed ID bounds' do
    with_tmpdir do |dir|
      _pool, range = build_range(root: dir)
      range.configure(1_000_000, 65_536, 4)

      expect(range.allocate(1, owner: 'user:alice')).to eq(
        block_index: 0,
        block_count: 1,
        owner: 'user:alice',
        first_id: 1_000_000,
        last_id: 1_065_535,
        id_count: 65_536
      )
    end
  end

  it 'persists explicit block allocations' do
    with_tmpdir do |dir|
      pool, range = build_range(root: dir)
      range.configure(1_000_000, 65_536, 4)

      range.allocate(1, block_index: 2, owner: 'user:alice')
      reloaded = described_class.new(pool, 'default')

      expect(reloaded.export_at(2)).to include(
        type: :allocated,
        block_index: 2,
        block_count: 1,
        owner: 'user:alice',
        first_id: 1_131_072,
        last_id: 1_196_607,
        id_count: 65_536
      )
    end
  end

  it 'frees allocations by block index and persists the change' do
    with_tmpdir do |dir|
      pool, range = build_range(root: dir)
      range.configure(1_000_000, 65_536, 4)
      range.allocate(1, owner: 'user:alice')

      range.free_at(0)
      reloaded = described_class.new(pool, 'default')

      expect(reloaded.export).to include(allocated: 0, free: 4)
    end
  end

  it 'frees allocations by owner' do
    with_tmpdir do |dir|
      pool, range = build_range(root: dir)
      range.configure(1_000_000, 65_536, 4)
      range.allocate(1, owner: 'user:alice')
      range.allocate(1, block_index: 2, owner: 'user:bob')

      range.free_by('user:alice')
      reloaded = described_class.new(pool, 'default')

      expect(reloaded.export_allocated).to eq([
                                                {
                                                  block_index: 2,
                                                  block_count: 1,
                                                  owner: 'user:bob',
                                                  first_id: 1_131_072,
                                                  last_id: 1_196_607,
                                                  id_count: 65_536
                                                }
                                              ])
    end
  end

  it 'allows deletion only when there are no allocations' do
    with_tmpdir do |dir|
      _pool, range = build_range(root: dir)
      range.configure(1_000_000, 65_536, 4)

      expect(range.can_delete?).to be(true)

      range.allocate(1, owner: 'user:alice')

      expect(range.can_delete?).to be(false)
    end
  end

  it 'updates and removes custom attributes' do
    with_tmpdir do |dir|
      pool, range = build_range(root: dir)
      range.configure(1_000_000, 65_536, 4)

      range.set(attrs: { 'org.vpsfree.cz/test:role' => 'system' })
      expect(load_yaml_file(range.config_path)).to include(
        'attrs' => { 'org.vpsfree.cz/test:role' => 'system' }
      )

      range.unset(attrs: ['org.vpsfree.cz/test:role'])
      reloaded = described_class.new(pool, 'default')

      expect(reloaded.attrs.dump).to eq({})
    end
  end

  it 'exports range summaries and individual segments' do
    with_tmpdir do |dir|
      _pool, range = build_range(root: dir)
      range.configure(1_000_000, 65_536, 4)
      range.allocate(1, owner: 'user:alice')
      range.allocate(1, block_index: 2, owner: 'user:bob')

      expect(range.export).to include(
        pool: 'tank',
        name: 'default',
        start_id: 1_000_000,
        last_id: 1_262_143,
        block_size: 65_536,
        block_count: 4,
        allocated: 2,
        free: 2
      )
      expect(range.export_all).to include(
        include(
          type: :allocated,
          block_index: 0,
          block_count: 1,
          owner: 'user:alice',
          first_id: 1_000_000,
          last_id: 1_065_535,
          id_count: 65_536
        ),
        include(
          type: :free,
          block_index: 1,
          block_count: 1,
          first_id: 1_065_536,
          last_id: 1_131_071,
          id_count: 65_536
        )
      )
      expect(range.export_free).to eq([
                                        {
                                          block_index: 1,
                                          block_count: 1,
                                          first_id: 1_065_536,
                                          last_id: 1_131_071,
                                          id_count: 65_536
                                        },
                                        {
                                          block_index: 3,
                                          block_count: 1,
                                          first_id: 1_196_608,
                                          last_id: 1_262_143,
                                          id_count: 65_536
                                        }
                                      ])
      expect(range.export_at(2)).to include(
        type: :allocated,
        block_index: 2,
        block_count: 1,
        owner: 'user:bob'
      )
    end
  end

  it 'round-trips allocations and attrs through config' do
    with_tmpdir do |dir|
      pool, range = build_range(root: dir)

      range.configure(1_000_000, 65_536, 4)
      alloc = range.allocate(1, owner: 'user:alice')
      range.set(attrs: { 'org.vpsfree.cz/test:role' => 'system' })

      reloaded = described_class.new(pool, 'default')

      expect(reloaded.export).to include(
        start_id: 1_000_000,
        block_size: 65_536,
        block_count: 4,
        allocated: 1,
        free: 3
      )
      expect(reloaded.export_at(alloc[:block_index])).to include(
        owner: 'user:alice',
        first_id: 1_000_000,
        last_id: 1_065_535,
        id_count: 65_536
      )
      expect(reloaded.attrs['org.vpsfree.cz/test:role']).to eq('system')
    end
  end

  it 'wraps allocation failures in AllocationError' do
    with_tmpdir do |dir|
      _pool, range = build_range(root: dir)
      range.configure(1_000_000, 65_536, 4)

      expect do
        range.allocate(1, block_index: -1, owner: 'user:alice')
      end.to raise_error(described_class::AllocationError, /allocate/i)
    end
  end
end
