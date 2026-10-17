# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Prebuild do
  let(:nix) { instance_double(TestRunner::NixCli, local_max_jobs: 20) }
  let(:pool) do
    TestRunner::ResourcePool.from_options(
      {
        resource_detector: resource_detector(memory_mib: 64_000, memory_available_mib: 48_000),
        memory_reserve_mib: 8000
      }, env: {}
    )
  end

  before do
    allow(TestRunner::NixCli).to receive(:new).and_return(nix)
  end

  def prepare(scripts, dir, **opts, &block)
    described_class.new(
      scripts, resource_pool: pool, state_dir: dir,
               root_directory: File.join(dir, 'roots'), **opts
    ).open(&block)
  end

  def stub_batch(&change)
    allow(nix).to receive(:build_test_batch) do |requests, root, **options|
      entries = requests.map do |request|
        path = "/nix/store/prepared-#{request.fetch(:id)}.json"
        data = JSON.generate(
          'machines' => {},
          'testScripts' => { 'default' => { 'script' => '' }, 'extra' => { 'script' => '' } }
        )
        allow(File).to receive(:read).with(path).and_return(data)
        allow(File).to receive(:file?).with(path).and_return(true)
        { 'id' => request.fetch(:id), 'json' => path }
      end
      change&.call(entries, requests, options)
      File.write(root, JSON.generate(entries))
    end
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:file?).and_call_original
  end

  it 'prepares only selected tests once, preserving arguments and retaining its root through runtime cleanup' do
    test = build_test(test_args: { 'variant' => 'a' }, scripts: { 'default' => {}, 'extra' => {} })
    template = build_test(path: 'template@a', type: 'template', template_args: { 'version' => 'a' })
    stub_batch
    with_tmpdir do |dir|
      prepare([*test.test_scripts.values, template.test_scripts.fetch('default')], dir) do |configs|
        expect(configs.keys).to contain_exactly(test, template)
        expect(configs.fetch(test)['testScripts'].keys).to include('default', 'extra')
        expect(Dir.glob(File.join(dir, 'roots/*.root')).length).to eq(1)
        # This block represents runtime, including its ensure/cleanup path.
        begin
          raise 'runtime error'
        ensure
          expect(Dir.glob(File.join(dir, 'roots/*.root')).length).to eq(1)
        end
      end
    rescue RuntimeError => e
      expect(e.message).to eq('runtime error')
      expect(Dir.glob(File.join(dir, 'roots/*.root'))).to be_empty
    end
    expect(nix).to have_received(:build_test_batch) do |requests, _root, max_jobs:, log_path:|
      expect(requests.size).to eq(2)
      expect(requests.map { |request| request.fetch(:path) }).to contain_exactly(test.path, template.path)
      expect(requests.first.fetch(:testArgs)).to eq('variant' => 'a')
      expect(requests.last.fetch(:templateArgs)).to eq('version' => 'a')
      expect(max_jobs).to eq(4)
      expect(File.basename(log_path)).to eq('build.log')
    end
  end

  it 'skips all preparation for an empty selection' do
    allow(nix).to receive(:build_test_batch)
    with_tmpdir { |dir| prepare([], dir) { |configs| expect(configs).to eq({}) } }
    expect(nix).not_to have_received(:build_test_batch)
  end

  it 'does not classify an empty runtime failure as preparation failure' do
    with_tmpdir do |dir|
      expect { prepare([], dir) { raise 'runtime failure' } }.to raise_error('runtime failure')
    end
  end

  it 'fails preparation before runtime and keeps selection/build diagnostics' do
    test = build_test(expect_failure: true)
    allow(nix).to receive(:build_test_batch) do |_requests, _root, **options|
      File.write(options.fetch(:log_path), 'builder died with signal 9 (KILL)')
      raise 'signal 9 (KILL)'
    end
    with_tmpdir do |dir|
      expect do
        prepare([build_test_script(test)], dir) { raise 'runtime was entered' }
      end.to raise_error(/Test preparation failed: signal 9 \(KILL\); build log:/)
      expect(Dir.glob(File.join(dir, 'roots/*.root'))).to be_empty
      expect(File.read(Dir.glob(File.join(dir, 'prebuild-*/build.log')).first)).to include('signal 9')
      expect(JSON.parse(File.read(Dir.glob(File.join(dir, 'prebuild-*/selection.json')).first)).size).to eq(1)
      expect(Dir.glob(File.join(dir, '**/test-result.txt'))).to be_empty
    end
  end

  %w[missing duplicate unexpected].each do |kind|
    it "rejects a #{kind} manifest identity before runtime" do
      stub_batch do |entries|
        entries.clear if kind == 'missing'
        entries << entries.first if kind == 'duplicate'
        entries.first['id'] = 'wrong' if kind == 'unexpected'
      end
      with_tmpdir do |dir|
        expect do
          prepare([build_test_script], dir) { raise 'runtime was entered' }
        end.to raise_error(/manifest has missing, duplicate, or unexpected/)
      end
    end
  end

  it 'validates selected scripts before entering runtime' do
    test = build_test(scripts: { 'missing' => {} })
    stub_batch
    with_tmpdir do |dir|
      expect do
        prepare(test.test_scripts.values, dir) { raise 'runtime was entered' }
      end.to raise_error(/Missing or invalid prepared script/)
    end
  end

  it 'releases its own root after cancellation without entering runtime' do
    allow(nix).to receive(:build_test_batch).and_raise(Interrupt)
    with_tmpdir do |dir|
      expect { prepare([build_test_script], dir) { raise 'runtime was entered' } }.to raise_error(Interrupt)
      expect(Dir.glob(File.join(dir, 'roots/*.root'))).to be_empty
    end
  end

  it 'honors remote-only max-jobs even with unknown headroom' do
    allow(nix).to receive(:local_max_jobs).and_return(0)
    allow(pool).to receive(:prebuild_memory_mib).and_return(nil)
    stub_batch
    with_tmpdir { |dir| prepare([build_test_script], dir) { |configs| expect(configs.size).to eq(1) } }
    expect(nix).to have_received(:build_test_batch).with(anything, anything, max_jobs: 0, log_path: anything)
  end

  it 'rejects unknown local headroom instead of selecting unbounded jobs' do
    allow(pool).to receive(:prebuild_memory_mib).and_return(nil)
    with_tmpdir do |dir|
      expect { prepare([build_test_script], dir) { raise 'runtime was entered' } }.to raise_error(/Unable to detect preparation memory/)
    end
  end

  it 'rejects insufficient local headroom instead of coercing zero jobs into one' do
    allow(pool).to receive(:prebuild_memory_mib).and_return(8191)
    with_tmpdir do |dir|
      expect { prepare([build_test_script], dir) { raise 'runtime was entered' } }.to raise_error(/Insufficient preparation memory/)
    end
  end

  it 'uses the positive estimate and inherited numeric max-jobs without a CPU clamp' do
    allow(nix).to receive(:local_max_jobs).and_return(30)
    allow(pool).to receive(:prebuild_memory_mib).and_return(64_000)
    stub_batch
    with_tmpdir { |dir| prepare([build_test_script], dir, memory_per_job_mib: 1000) { |configs| expect(configs.size).to eq(1) } }
    expect(nix).to have_received(:build_test_batch).with(anything, anything, max_jobs: 30, log_path: anything)
  end

  it 'rejects a non-positive estimate' do
    expect do
      described_class.new([], resource_pool: pool, state_dir: '/tmp/state', memory_per_job_mib: 0)
    end.to raise_error(ArgumentError, /must be positive/)
  end
end
