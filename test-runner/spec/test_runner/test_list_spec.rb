# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::TestList do
  let(:nix) { instance_double(TestRunner::NixCli) }

  before do
    allow(TestRunner::NixCli).to receive(:new).and_return(nix)
  end

  it 'parses many tests from json' do
    allow(nix).to receive(:eval_tests_meta_all).and_return(
      JSON.dump(
        'suite/a' => {
          'type' => 'test',
          'template' => nil,
          'templateArgs' => {},
          'testArgs' => {},
          'name' => 'a',
          'description' => 'A',
          'attempts' => 1,
          'expectFailure' => false,
          'testScriptJobs' => 2,
          'resources' => {
            'machines' => 1,
            'memoryMiB' => 2048,
            'shmMiB' => 2048,
            'maxMachineMemoryMiB' => 2048,
            'cpus' => 2
          },
          'tags' => [],
          'labels' => {},
          'testScripts' => { 'default' => {} }
        }
      )
    )

    tests = described_class.new.all

    expect(tests.map(&:path)).to eq(['suite/a'])
    expect(tests.first.test_script_jobs).to eq(2)
    expect(tests.first.resources.memory_mib).to eq(2048)
  end

  it 'parses one test from json' do
    allow(nix).to receive(:eval_test_meta).with('suite/a').and_return(
      JSON.dump(
        'type' => 'test',
        'template' => nil,
        'templateArgs' => {},
        'testArgs' => {},
        'name' => 'a',
        'description' => 'A',
        'attempts' => 1,
        'expectFailure' => false,
        'tags' => [],
        'labels' => {},
        'testScripts' => { 'default' => {} }
      )
    )

    test = described_class.new.by_path('suite/a')

    expect(test.path).to eq('suite/a')
  end

  it 'filters tests with the given block' do
    list = described_class.new
    allow(list).to receive(:all).and_return([build_test(name: 'a'), build_test(name: 'b')])

    expect(list.filter { |test| test.name == 'b' }.map(&:name)).to eq(['b'])
  end

  it 'delegates by_path through nix metadata lookup' do
    list = described_class.new
    allow(list).to receive(:extract_one).with('suite/a').and_return(
      JSON.dump(
        'type' => 'test',
        'template' => nil,
        'templateArgs' => {},
        'testArgs' => {},
        'name' => 'a',
        'description' => 'A',
        'attempts' => 1,
        'expectFailure' => false,
        'tags' => [],
        'labels' => {},
        'testScripts' => { 'default' => {} }
      )
    )

    expect(list.by_path('suite/a').path).to eq('suite/a')
  end

  it 'builds nested test scripts' do
    allow(nix).to receive(:eval_test_meta).with('suite/a').and_return(
      JSON.dump(
        'type' => 'test',
        'template' => nil,
        'templateArgs' => {},
        'testArgs' => {},
        'name' => 'a',
        'description' => 'A',
        'attempts' => 1,
        'expectFailure' => false,
        'tags' => [],
        'labels' => {},
        'testScripts' => {
          'smoke' => { 'description' => 'Smoke', 'attempts' => 3 }
        }
      )
    )

    test = described_class.new.by_path('suite/a')

    expect(test.test_scripts['smoke'].description).to eq('Smoke')
    expect(test.test_scripts['smoke'].attempts).to eq(3)
  end
end
