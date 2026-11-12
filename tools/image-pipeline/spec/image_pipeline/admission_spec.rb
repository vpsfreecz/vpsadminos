require_relative '../spec_helper'
require_relative '../../lib/image_pipeline/admission'
require_relative '../../lib/image_pipeline/coordinator'

RSpec.describe ImagePipeline::Admission do
  let(:config) { { 'memory' => 8192, 'cpus' => 2, 'disks' => [{ 'size' => '32G' }] } }
  let(:profile) do
    { memory_mib: 96 * 1024, memory_available_mib: 80 * 1024,
      shm_mib: 64 * 1024, shm_available_mib: 56 * 1024, cpus: 16 }
  end
  let(:detector) { instance_double(TestRunner::ResourcePool::HostResourceDetector, **profile) }

  before do
    allow(TestRunner::ResourcePool).to receive(:detect_df_mib).with('/state', 3).and_return(1024 * 1024)
  end

  def admit(**opts)
    described_class.new(config:, state_dir: '/state', item_count: 20, env: {}, resource_detector: detector, **opts)
  end

  it 'uses the real pool and changes the next job count when runner resources change without inventory variables' do
    first = admit
    expect(first.workers).to eq(6)
    expect(first.evidence.fetch('capacity')).to eq(memory_mib: 72 * 1024, shm_mib: 48 * 1024, cpus: 24)
    expect(first.evidence.fetch('worker')).to eq('memory_mib' => 8192, 'shm_mib' => 8192, 'cpus' => 2)
    allow(detector).to receive_messages(memory_mib: 32 * 1024, memory_available_mib: 24 * 1024,
                                        shm_mib: 24 * 1024, shm_available_mib: 16 * 1024, cpus: 4)
    second = admit
    expect(second.workers).to eq(1)
    expect(first.workers).to eq(6)
    expect(second.evidence.fetch('sample').fetch(:memory_available_mib)).to eq(24 * 1024)
    expect(first.evidence.fetch('policy').fetch('defaults').fetch('cpu_overcommit')).to eq(1.5)
    expect(first.evidence.fetch('policy').fetch('environment')).to be_empty
  end

  it 'keeps selected count, auto, numeric worker limits and legacy host caps as upper bounds' do
    expect(admit(item_count: 2).workers).to eq(2)
    expect(admit(workers: 'auto').workers).to eq(6)
    expect(admit(workers: '1').workers).to eq(1)
    expect(admit(workers: 3).workers).to eq(3)
    expect(admit(max_memory_mib: 24 * 1024).workers).to eq(2)
    expect(admit(max_cpus: 4).workers).to eq(2)
    expect(admit(max_memory_mib: 1024 * 1024, max_cpus: 1000).workers).to eq(6)
  end

  it 'retains TEST_RUNNER policy overrides and precedence through the real pool' do
    env = { 'TEST_RUNNER_MEMORY_RESERVE_MIB' => '0', 'TEST_RUNNER_SHM_RESERVE_MIB' => '0',
            'TEST_RUNNER_MAX_MEMORY_MIB' => '32768', 'TEST_RUNNER_MAX_SHM_MIB' => '8192',
            'TEST_RUNNER_MAX_CPUS' => '2', 'TEST_RUNNER_CPU_OVERCOMMIT' => '1',
            'UNRELATED_SECRET' => 'never-record-this' }
    result = admit(env:)
    expect(result.workers).to eq(1)
    expect(result.evidence.fetch('capacity')).to eq(memory_mib: 32_768, shm_mib: 8192, cpus: 2)
    expect(result.evidence.fetch('policy').fetch('environment')).not_to have_key('UNRELATED_SECRET')
  end

  it 'refuses unknown and zero observations even when explicit maximums could supply fallback capacity' do
    profile.each_key do |name|
      [nil, 0].each do |missing|
        allow(detector).to receive_messages(**profile, name => missing)
        expect { admit(max_memory_mib: 1024 * 1024, max_cpus: 1000) }
          .to raise_error(ArgumentError, /known positive #{name}/)
      end
    end
  end

  it 'refuses a worker that does not fit rather than applying the oversized-alone test escape' do
    expect { admit(max_memory_mib: 8192) }.to raise_error(ArgumentError, /after reserves/)
    expect { admit(max_cpus: 1) }.to raise_error(ArgumentError, /no image worker fits/)
    [0, -1, 'invalid', 1.5].each do |cap|
      expect { admit(workers: cap) }.to raise_error(ArgumentError)
    end
    %w[memory cpus].each do |dimension|
      expect { admit(config: config.merge(dimension => 0)) }.to raise_error(ArgumentError)
    end
  end

  it 'checks minimum configured disk space on the actual state filesystem without shrinking the pool to disk' do
    allow(TestRunner::ResourcePool).to receive(:detect_df_mib).with('/state', 3).and_return(64 * 1024)
    result = admit(workers: 2)
    expect(result.evidence.fetch('disk')).to eq('available_mib' => 65_536, 'per_worker_mib' => 32_768,
                                                'minimum_required_mib' => 65_536)
    [nil, 0, 65_535].each do |free|
      allow(TestRunner::ResourcePool).to receive(:detect_df_mib).with('/state', 3).and_return(free)
      expect { admit(workers: 2) }.to raise_error(ArgumentError, /filesystem lacks known free space/)
    end
    expect { admit(config: config.merge('disks' => [{ 'size' => 'unknown' }])) }
      .to raise_error(ArgumentError, /worker disk size/)
  end

  it 'loads through the normal OsVm script command without loading the test-runner CLI' do
    with_tmpdir do |dir|
      script = File.join(dir, 'load-admission.rb')
      File.write(script, <<~RUBY)
        require #{File.join(REPO_ROOT, 'tools/image-pipeline/lib/image_pipeline/admission').inspect}
        abort 'test-runner CLI loaded' if TestRunner.const_defined?(:Cli)
        puts 'image admission loaded'
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, '-I', $:.join(File::PATH_SEPARATOR),
                                       File.join(REPO_ROOT, 'osvm/bin/osvm'), 'script', script)
      expect(status.success?).to be(true), output
      expect(output).to include('image admission loaded')
    end
  end

  it 'preserves the empty-selection exit before admission, source capture or producer state' do
    with_tmpdir do |dir|
      source = File.join(dir, 'source')
      FileUtils.mkdir_p(source)
      plan, inputs = %w[plan.json inputs.json].map { |name| File.join(dir, name) }
      File.write(plan, JSON.generate('items' => []))
      File.write(inputs, '{}')
      allow(IO).to receive(:popen).with(['git', '-C', source, 'rev-parse', 'HEAD']).and_return('a' * 40)
      allow(described_class).to receive(:new)
      allow(Open3).to receive(:pipeline)
      allow(ImagePipeline::Control).to receive(:new)
      original_argv = ARGV.dup
      begin
        ARGV.replace(['--plan', plan, '--source-dir', source, '--state-dir', File.join(dir, 'state'),
                      '--event', 'workflow_dispatch', '--ref', 'refs/heads/feature', '--input-graph', inputs])
        expect do
          expect { load File.join(REPO_ROOT, 'tools/image-pipeline/build.rb') }
            .to raise_error(SystemExit) { |error| expect(error.status).to eq(0) }
        end.to output("No configured image changes; skipping candidate run\n").to_stderr
        expect(described_class).not_to have_received(:new)
        expect(Open3).not_to have_received(:pipeline)
        expect(ImagePipeline::Control).not_to have_received(:new)
      ensure
        ARGV.replace(original_argv)
      end
    end
  end

  it 'samples after source preparation and refuses before producer begin or any worker construction' do
    with_tmpdir do |dir|
      source = File.join(dir, 'source')
      state = File.join(dir, 'state')
      FileUtils.mkdir_p(File.join(source, 'image-scripts/images/quick'))
      File.write(File.join(source, 'image-scripts/images/quick/config.sh'), "BUILDER=alpine\n")
      plan = File.join(dir, 'plan.json')
      machine = File.join(dir, 'machine.json')
      inputs = File.join(dir, 'inputs.json')
      File.write(plan, JSON.generate('items' => [{ 'name' => 'quick' }]))
      File.write(machine, JSON.generate('machines' => { 'machine' => config }))
      File.write(inputs, '{}')
      allow(IO).to receive(:popen).with(['git', '-C', source, 'rev-parse', 'HEAD']).and_return('a' * 40)
      allow(Open3).to receive(:pipeline).and_return([instance_double(Process::Status, success?: true)])
      allow(TestRunner::ResourcePool::HostResourceDetector).to receive(:new).and_return(detector)
      allow(detector).to receive(:memory_mib) do
        expect(File).to exist(File.join(state, 'source/.vpsadminos-git-rev'))
        nil
      end
      allow(ImagePipeline::Control).to receive(:new)
      allow(ImagePipeline::Coordinator).to receive(:new)
      original_argv = ARGV.dup
      begin
        ARGV.replace(['--machine-config', machine, '--plan', plan, '--source-dir', source,
                      '--state-dir', state, '--event', 'workflow_dispatch', '--ref', 'refs/heads/feature',
                      '--input-graph', inputs])
        expect { load File.join(REPO_ROOT, 'tools/image-pipeline/build.rb') }
          .to raise_error(ArgumentError, /known positive memory_mib/)
        expect(ImagePipeline::Control).not_to have_received(:new)
        expect(ImagePipeline::Coordinator).not_to have_received(:new)
      ensure
        ARGV.replace(original_argv)
      end
    end
  end
end
