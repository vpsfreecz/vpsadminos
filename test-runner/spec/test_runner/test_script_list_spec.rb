# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::TestScriptList do
  let(:test_list) { instance_double(TestRunner::TestList) }

  before do
    allow(TestRunner::TestList).to receive(:new).and_return(test_list)
  end

  it 'expands all scripts from all tests' do
    test = build_test(
      scripts: {
        'smoke' => {},
        'full' => {}
      }
    )
    allow(test_list).to receive(:all).and_return([test])

    expect(described_class.new.all.map(&:name)).to contain_exactly('smoke', 'full')
  end

  it 'filters expanded scripts' do
    test = build_test(
      scripts: {
        'smoke' => {},
        'full' => {}
      }
    )
    allow(test_list).to receive(:all).and_return([test])

    expect(described_class.new.filter { |script| script.name == 'smoke' }.map(&:name)).to eq(['smoke'])
  end

  it 'resolves explicit test#script paths' do
    test = build_test(scripts: { 'smoke' => {}, 'full' => {} })
    allow(test_list).to receive(:by_path).with('suite/example').and_return(test)

    expect(described_class.new.by_path('suite/example#smoke').name).to eq('smoke')
  end

  it 'returns the lone script when no suffix is provided' do
    test = build_test
    allow(test_list).to receive(:by_path).with('suite/example').and_return(test)

    expect(described_class.new.by_path('suite/example')).to eq(test.test_scripts['default'])
  end

  it 'raises when multi-script tests are accessed without a suffix' do
    test = build_test(scripts: { 'smoke' => {}, 'full' => {} })
    allow(test_list).to receive(:by_path).with('suite/example').and_return(test)

    expect do
      described_class.new.by_path('suite/example')
    end.to raise_error(RuntimeError, /choose one/)
  end

  it 'raises clearly for unknown scripts' do
    test = build_test(scripts: { 'smoke' => {} })
    allow(test_list).to receive(:by_path).with('suite/example').and_return(test)

    expect do
      described_class.new.by_path('suite/example#missing')
    end.to raise_error(RuntimeError, 'Test suite/example does not have script #missing')
  end
end
