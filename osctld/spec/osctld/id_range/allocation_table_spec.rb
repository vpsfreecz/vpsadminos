# frozen_string_literal: true

require 'osctld/id_range/allocation_table'

RSpec.describe OsCtld::IdRange::AllocationTable do
  def build_seeded_table
    described_class.load(10, [
                           {
                             'block_index' => 2,
                             'block_count' => 2,
                             'owner' => 'user:alice'
                           },
                           {
                             'block_index' => 6,
                             'block_count' => 1,
                             'owner' => 'user:bob'
                           }
                         ])
  end

  it 'reports all blocks as free in an empty table' do
    table = described_class.new(10)

    expect(table).to be_empty
    expect(table.count_allocated_blocks).to eq(0)
    expect(table.count_free_blocks).to eq(10)
    expect(table.export_free).to eq([{ block_index: 0, block_count: 10 }])
    expect(table.export_at(0)).to eq(
      type: :free,
      block_index: 0,
      block_count: 10,
      owner: nil
    )
  end

  it 'allocates into the first free segment' do
    table = described_class.new(10)

    expect(table.allocate(2, 'user:alice')).to eq(
      block_index: 0,
      block_count: 2,
      owner: 'user:alice'
    )
    expect(table.allocate(1, 'user:bob')).to eq(
      block_index: 2,
      block_count: 1,
      owner: 'user:bob'
    )
  end

  it 'keeps explicit allocations sorted by block index' do
    table = described_class.new(10)

    table.allocate_at(5, 1, 'user:bob')
    table.allocate_at(2, 2, 'user:alice')

    expect(table.export_allocated.map { |v| v[:block_index] }).to eq([2, 5])
  end

  it 'detects free gaps that fit the requested size' do
    table = build_seeded_table

    expect(table.free_at?(0, 2)).to be(true)
    expect(table.free_at?(4, 2)).to be(true)
    expect(table.free_at?(7, 3)).to be(true)
    expect(table.free_at?(4, 3)).to be(false)
  end

  it 'frees an allocation by its starting block index' do
    table = build_seeded_table

    expect(table.free_at(2)).to be(true)
    expect(table.free_at(2)).to be(false)
    expect(table.export_allocated).to eq([
                                           {
                                             block_index: 6,
                                             block_count: 1,
                                             owner: 'user:bob'
                                           }
                                         ])
  end

  it 'frees all allocations owned by a given owner' do
    table = described_class.new(10)
    table.allocate_at(0, 1, 'user:alice')
    table.allocate_at(2, 2, 'user:bob')
    table.allocate_at(5, 1, 'user:alice')

    expect(table.free_by('user:alice')).to be(true)
    expect(table.export_allocated).to eq([
                                           {
                                             block_index: 2,
                                             block_count: 2,
                                             owner: 'user:bob'
                                           }
                                         ])
  end

  it 'counts allocated and free blocks' do
    table = build_seeded_table

    expect(table.count_allocated_blocks).to eq(3)
    expect(table.count_free_blocks).to eq(7)
  end

  it 'exports allocated and free segments' do
    table = build_seeded_table

    expect(table.export_all).to eq([
                                     {
                                       type: :free,
                                       block_index: 0,
                                       block_count: 2,
                                       owner: nil
                                     },
                                     {
                                       type: :allocated,
                                       block_index: 2,
                                       block_count: 2,
                                       owner: 'user:alice'
                                     },
                                     {
                                       type: :free,
                                       block_index: 4,
                                       block_count: 2,
                                       owner: nil
                                     },
                                     {
                                       type: :allocated,
                                       block_index: 6,
                                       block_count: 1,
                                       owner: 'user:bob'
                                     },
                                     {
                                       type: :free,
                                       block_index: 7,
                                       block_count: 3,
                                       owner: nil
                                     }
                                   ])
    expect(table.export_allocated).to eq([
                                           {
                                             block_index: 2,
                                             block_count: 2,
                                             owner: 'user:alice'
                                           },
                                           {
                                             block_index: 6,
                                             block_count: 1,
                                             owner: 'user:bob'
                                           }
                                         ])
    expect(table.export_free).to eq([
                                      {
                                        block_index: 0,
                                        block_count: 2
                                      },
                                      {
                                        block_index: 4,
                                        block_count: 2
                                      },
                                      {
                                        block_index: 7,
                                        block_count: 3
                                      }
                                    ])
    expect(table.export_at(6)).to eq(
      type: :allocated,
      block_index: 6,
      block_count: 1,
      owner: 'user:bob'
    )
  end

  it 'round-trips from dumped allocations' do
    table = build_seeded_table
    loaded = described_class.load(10, table.dump)

    expect(loaded.export_allocated).to eq(table.export_allocated)
  end

  it 'loads allocations from the legacy index and count keys' do
    allocation = described_class::Allocation.load(
      'index' => 3,
      'count' => 2,
      'owner' => 'user:alice'
    )

    expect(allocation.export).to eq(
      block_index: 3,
      block_count: 2,
      owner: 'user:alice'
    )
  end

  it 'rejects a first allocation that starts before the table' do
    table = described_class.new(10)

    expect { table.allocate_at(-1, 1, 'user:alice') }
      .to raise_error(ArgumentError, /allocate/i)
  end

  it 'rejects a first allocation that extends beyond block_count' do
    table = described_class.new(10)

    expect { table.allocate_at(9, 2, 'user:alice') }
      .to raise_error(ArgumentError, /allocate/i)
  end
end
