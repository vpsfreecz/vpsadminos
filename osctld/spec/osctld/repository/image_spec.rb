# frozen_string_literal: true

require 'osctld/repository/image'

RSpec.describe OsCtld::Repository::Image do
  it 'is not cached when the cached formats list is empty' do
    image = described_class.new(
      vendor: 'vpsfree',
      variant: 'default',
      arch: 'x86_64',
      distribution: 'alpine',
      version: '3.20',
      tags: ['latest'],
      cached: []
    )

    expect(image.cached?).to be(false)
  end

  it 'is cached when at least one format is cached' do
    image = described_class.new(
      vendor: 'vpsfree',
      variant: 'default',
      arch: 'x86_64',
      distribution: 'alpine',
      version: '3.20',
      tags: ['latest'],
      cached: [:tar]
    )

    expect(image.cached?).to be(true)
  end

  it 'dumps all attributes with the cached boolean state' do
    image = described_class.new(
      vendor: 'vpsfree',
      variant: 'default',
      arch: 'x86_64',
      distribution: 'alpine',
      version: '3.20',
      tags: ['latest'],
      cached: [:tar]
    )

    expect(image.dump).to eq(
      vendor: 'vpsfree',
      variant: 'default',
      arch: 'x86_64',
      distribution: 'alpine',
      version: '3.20',
      tags: ['latest'],
      cached: true
    )
  end
end
