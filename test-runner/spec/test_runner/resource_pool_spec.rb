# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::ResourcePool do
  def build_pool(**opts)
    described_class.from_options(
      {
        max_memory_mib: nil,
        max_shm_mib: nil,
        max_cpus: nil,
        memory_reserve_mib: 0,
        shm_reserve_mib: 0,
        cpu_reserve: 0,
        resource_detector:
      }.merge(opts)
    )
  end

  it 'refreshes detected capacity and applies explicit max values as ceilings' do
    pool = build_pool(
      max_memory_mib: 36_000,
      max_cpus: 10,
      memory_reserve_mib: 4000,
      shm_reserve_mib: 1000,
      cpu_reserve: 1,
      resource_detector: resource_detector(
        memory_available_mib: [32_000, 40_000],
        shm_available_mib: [16_000, 18_000],
        cpus: [8, 12]
      )
    )

    expect(pool.memory_mib).to eq(28_000)
    expect(pool.shm_mib).to eq(15_000)
    expect(pool.cpus).to eq(7)

    expect(pool.refresh_capacity).to be(true)
    expect(pool.memory_mib).to eq(32_000)
    expect(pool.shm_mib).to eq(17_000)
    expect(pool.cpus).to eq(9)
  end

  it 'falls back to explicit max values when detection fails' do
    pool = build_pool(
      max_memory_mib: 16_000,
      max_cpus: 6,
      memory_reserve_mib: 4000,
      cpu_reserve: 1,
      resource_detector: resource_detector
    )

    expect(pool.memory_mib).to eq(12_000)
    expect(pool.shm_mib).to be_nil
    expect(pool.cpus).to eq(5)
  end

  it 'keeps unlimited capacity when detection and explicit max values are absent' do
    pool = build_pool(resource_detector: resource_detector)

    expect(pool.memory_mib).to be_nil
    expect(pool.shm_mib).to be_nil
    expect(pool.cpus).to be_nil
  end

  it 'adds already reserved memory and shm to refreshed available capacity' do
    pool = build_pool(
      resource_detector: resource_detector(
        memory_available_mib: [16_000, 12_000],
        shm_available_mib: [8000, 6000],
        cpus: 8
      )
    )

    pool.reserve(TestRunner::TestResources.new(memory_mib: 4000, shm_mib: 2000, cpus: 4))

    expect(pool.refresh_capacity).to be(false)
    expect(pool.memory_mib).to eq(16_000)
    expect(pool.shm_mib).to eq(8000)
    expect(pool.cpus).to eq(8)
  end

  it 'does not add already reserved cpus to refreshed cpu capacity' do
    pool = build_pool(
      resource_detector: resource_detector(cpus: [8, 6])
    )

    pool.reserve(TestRunner::TestResources.new(cpus: 4))

    expect(pool.refresh_capacity).to be(true)
    expect(pool.cpus).to eq(6)
  end
end
