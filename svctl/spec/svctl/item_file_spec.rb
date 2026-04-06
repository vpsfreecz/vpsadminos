# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SvCtl::ItemFile do
  let(:dir) { Dir.mktmpdir('spec') }
  let(:path) { File.join(dir, 'items.txt') }

  after do
    FileUtils.rm_rf(dir)
  end

  it 'ignores blank lines while parsing' do
    File.write(path, "first\n\n second \n\t\n")

    described_class.new(path) do |list|
      expect(list.get).to eq(%w[first second])
    end
  end

  it 'loads current contents, yields the list, and saves changes' do
    File.write(path, "first\n")

    yielded = nil

    described_class.new(path) do |list|
      yielded = list
      list << 'second'
    end

    expect(yielded).to be_a(described_class)
    expect(File.readlines(path, chomp: true)).to eq(%w[first second])
  end

  it 'deduplicates appended entries' do
    described_class.new(path) do |list|
      list << 'first'
      list << 'first'

      expect(list.get).to eq(['first'])
    end
  end

  it 'deletes entries from the list' do
    File.write(path, "first\nsecond\n")

    described_class.new(path) do |list|
      list.delete('first')

      expect(list.get).to eq(['second'])
    end
  end

  it 'removes the file when the list becomes empty' do
    File.write(path, "first\n")

    described_class.new(path) do |list|
      list.delete('first')
    end

    expect(File.exist?(path)).to be(false)
  end

  it 'raises when methods are called outside of an open block' do
    list = described_class.new(path)

    expect { list.get }.to raise_error(RuntimeError, 'file list not open')
    expect { list.each.to_a }.to raise_error(RuntimeError, 'file list not open')
    expect { list.include?('x') }.to raise_error(RuntimeError, 'file list not open')
    expect { list << 'x' }.to raise_error(RuntimeError, 'file list not open')
    expect { list.delete('x') }.to raise_error(RuntimeError, 'file list not open')
  end

  it 'reports open state only while inside the open block' do
    states = []

    list = described_class.new(path)
    states << list.open?

    list.open do |opened|
      states << opened.open?
    end

    states << list.open?

    expect(states).to eq([false, true, false])
  end
end
