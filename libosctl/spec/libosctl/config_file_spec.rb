# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/config_file'

RSpec.describe OsCtl::Lib::ConfigFile do
  describe '.load_yaml' do
    it 'loads YAML from a string' do
      expect(described_class.load_yaml("---\nfoo: bar\nnested:\n  baz: 1\n")).to eq(
        'foo' => 'bar',
        'nested' => { 'baz' => 1 }
      )
    end

    it 'rejects object deserialization' do
      expect do
        described_class.load_yaml("--- !ruby/object:Object {}\n")
      end.to raise_error(Psych::DisallowedClass)
    end
  end

  describe '.load_yaml_file' do
    it 'loads YAML from a file with BOM handling' do
      with_tmpdir do |dir|
        path = File.join(dir, 'config.yml')
        File.binwrite(path, "\xEF\xBB\xBF---\nfoo: bar\n")

        expect(described_class.load_yaml_file(path)).to eq('foo' => 'bar')
      end
    end
  end

  describe '.dump_yaml' do
    it 'round-trips dumped data through the loader' do
      data = { 'items' => [1, 2, 3], 'nested' => { 'enabled' => true } }

      expect(described_class.load_yaml(described_class.dump_yaml(data))).to eq(data)
    end
  end
end
