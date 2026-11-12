require_relative '../spec_helper'
require 'digest'
require 'rbconfig'
require 'yaml'
require_relative '../../lib/image_pipeline/coordinator'
require_relative '../../lib/image_pipeline/publisher'
require_relative '../../lib/image_pipeline/selection'

RSpec.describe ImagePipeline do
  describe 'suite repository readiness' do
    it 'seals build-only runs without requiring unchanged full-suite images or emitting a test configuration' do
      with_tmpdir do |dir|
        control = instance_double(ImagePipeline::Control)
        allow(control).to receive(:call) do |operation, *|
          case operation
          when 'begin' then { 'key' => 'run' }
          when 'seal' then { 'generation' => 'sealed', 'catalog' => { 'images' => [] } }
          else {}
          end
        end
        plan = { 'items' => [], 'defaults' => {}, 'dependencies' => [{ 'distribution' => 'historical', 'version' => 'old' }] }
        coordinator = ImagePipeline::Coordinator.new(control:, repository_url: 'https://images.example', source: {}, plan:,
                                                     state_dir: dir, run_id: 'run', attempt: 1, lease_seconds: 3600,
                                                     full_ci: false)
        expect(coordinator.finish).to eq('https://images.example/runs/run')
        expect(coordinator.ci_ready).to be(false)
        expect(Dir.glob(File.join(dir, 'test-config.*'))).to be_empty
      end
    end

    it 'preserves seal integrity errors in build-only mode' do
      with_tmpdir do |dir|
        control = instance_double(ImagePipeline::Control)
        allow(control).to receive(:call) do |operation, *|
          case operation
          when 'begin' then { 'key' => 'run' }
          when 'seal' then raise ImagePipeline::ControlError.new('code' => 'corrupt', 'message' => 'catalog corrupted')
          else {}
          end
        end
        coordinator = ImagePipeline::Coordinator.new(control:, repository_url: 'https://images.example', source: {},
                                                     plan: { 'items' => [], 'defaults' => {} }, state_dir: dir,
                                                     run_id: 'run', attempt: 1, lease_seconds: 3600, full_ci: false)
        expect { coordinator.finish }.to raise_error(ImagePipeline::ControlError) { |error| expect(error.code).to eq('corrupt') }
        expect(coordinator.ci_ready).to be(false)
      end
    end

    it 'uses the declared pinned NixOS tuple/variant requirements and rejects a missing unchanged variant' do
      with_tmpdir do |dir|
        json, _error, status = Open3.capture3('nix-instantiate', '--eval', '--strict', '--json', '--expr',
                                              "(import #{REPO_ROOT}/tests/image-repository-requirements.nix {}).all")
        expect(status.success?).to be(true)
        dependencies = JSON.parse(json).select { |dependency| dependency['distribution'] == 'nixos' }
        expect(dependencies).to contain_exactly(
          { 'distribution' => 'nixos', 'version' => '22.11', 'variant' => 'minimal' },
          { 'distribution' => 'nixos', 'version' => '24.05', 'variant' => 'impermanence' }
        )
        tuple = { 'vendor' => 'vpsadminos', 'arch' => 'x86_64', 'distribution' => 'nixos', 'tags' => [] }
        view = { 'generation' => 'sealed', 'catalog' => { 'vendors' => { 'default' => 'vpsadminos', 'vpsadminos' => 'minimal' },
                                                          'images' => [tuple.merge('version' => '22.11', 'variant' => 'minimal'),
                                                                       tuple.merge('version' => '24.05', 'variant' => 'minimal')] } }
        control = instance_double(ImagePipeline::Control)
        allow(control).to receive(:call) do |operation, *|
          case operation
          when 'begin' then { 'key' => 'run' }
          when 'seal' then view
          else {}
          end
        end
        plan = { 'items' => [], 'defaults' => {}, 'dependencies' => dependencies }
        coordinator = ImagePipeline::Coordinator.new(control:, repository_url: 'https://images.example', source: {}, plan:,
                                                     state_dir: dir, run_id: 'run', attempt: 1, lease_seconds: 3600, full_ci: true)
        expect { coordinator.finish }.to raise_error(/missing suite image dependency.*impermanence/)
        expect(File.exist?(File.join(dir, 'test-config.json'))).to be(false)
        expect(coordinator.ci_ready).to be(false)
        view.fetch('catalog').fetch('images') << tuple.merge('version' => '24.05', 'variant' => 'impermanence')
        expect(coordinator.finish).to eq('https://images.example/runs/run')
        expect(coordinator.ci_ready).to be(true)
        expect(JSON.parse(File.read(File.join(dir, 'test-config.json'))).fetch('imageRepository').fetch('url'))
          .to eq('https://images.example/runs/run')
      end
    end

    it 'matches explicit vendor, architecture and version tags instead of catalog defaults' do
      with_tmpdir do |dir|
        dependency = { 'vendor' => 'other', 'variant' => 'large', 'arch' => 'aarch64',
                       'distribution' => 'alpine', 'version' => 'stable' }
        view = { 'generation' => 'sealed',
                 'catalog' => { 'vendors' => { 'default' => 'vpsadminos', 'vpsadminos' => 'minimal' },
                                'images' => [dependency.merge('version' => '3.24', 'tags' => ['stable'])] } }
        control = instance_double(ImagePipeline::Control)
        allow(control).to receive(:call) do |operation, *|
          case operation
          when 'begin' then { 'key' => 'run' }
          when 'seal' then view
          else {}
          end
        end
        plan = { 'items' => [], 'defaults' => {}, 'dependencies' => [dependency] }
        coordinator = ImagePipeline::Coordinator.new(control:, repository_url: 'https://images.example', source: {}, plan:,
                                                     state_dir: dir, run_id: 'run', attempt: 1, lease_seconds: 3600, full_ci: true)
        expect(coordinator.finish).to eq('https://images.example/runs/run')
      end
    end
  end

  describe ImagePipeline::Coordinator do
    [false, true].each do |full_ci|
      it "publishes a good image independently when another fails (full CI requested: #{full_ci})" do
        with_tmpdir do |dir|
          calls = []
          control = instance_double(ImagePipeline::Control)
          allow(control).to receive(:call) do |operation, params = {}, **|
            calls << [operation, params]
            case operation
            when 'begin' then { 'key' => 'run-key' }
            when 'status' then { 'generation' => 'fresh', 'catalog' => { 'images' => [] } }
            else {}
            end
          end
          source = { 'sha' => 'a' * 40 }
          bad = { 'id' => 'bad', 'name' => 'bad', 'order' => 0, 'tags' => [], 'builder' => 'fedora' }
          good = { 'id' => 'good', 'name' => 'good', 'order' => 1, 'tags' => ['latest'], 'attempt' => 1 }
          plan = { 'items' => [bad, good], 'defaults' => {}, 'gc' => [], 'dependencies' => [] }
          coordinator = described_class.new(control:, repository_url: 'https://images.example', source:, plan:,
                                            state_dir: dir, run_id: 'workflow-1', attempt: 1, lease_seconds: 3600, full_ci:)
          expect(calls.first.last.fetch('expected')).to eq([
                                                             { 'id' => 'bad', 'order' => 0, 'tags' => [] },
                                                             { 'id' => 'good', 'order' => 1, 'tags' => ['latest'] }
                                                           ])
          coordinator.result(bad, 'status' => 'failed', 'message' => 'capture failed')
          FileUtils.mkdir_p(File.join(dir, 'worker-0'))
          payload = File.join(dir, 'worker-0', 'verified.tar')
          File.write(payload, 'tested bytes')
          coordinator.result(good, 'status' => 'verified', 'assignment' => { 'config_digest' => 'frozen' },
                                   'files' => [{ 'path' => payload, 'format' => 'zfs',
                                                 'size' => File.size(payload), 'sha256' => Digest::SHA256.file(payload).hexdigest }])
          expect(coordinator.finish).to be_nil
          expect(calls.map(&:first)).not_to include('seal')
          expect(calls.find { |op, p| op == 'result' && p['item_id'] == 'bad' }.last['attempt']).to eq(0)
          summary = { 'source' => source, 'plan' => plan, 'run' => coordinator.run, 'verified' => coordinator.verified }
          ImagePipeline::Publisher.new(summary, control).publish(source_dir: dir)
          expect(calls.last).to eq(['publish', { 'generation' => 'fresh', 'items' => ['good'],
                                                 'defaults' => {}, 'gc' => [], 'ancestors' => [] }])
        end
      end
    end

    it 'records an older same-source publication as superseded without applying its policy' do
      calls = []
      control = instance_double(ImagePipeline::Control)
      allow(control).to receive(:call) do |operation, params = {}, **|
        calls << [operation, params]
        case operation
        when 'status'
          { 'generation' => 'fresh', 'catalog' => { 'policy_source' => 'a' * 40, 'images' => [] } }
        when 'publish'
          if params.fetch('items').any?
            raise ImagePipeline::ControlError, { 'code' => 'superseded', 'message' => 'newer same-source admission' }
          end

          { 'generation' => 'fresh' }
        end
      end
      summary = { 'source' => { 'sha' => 'a' * 40 }, 'plan' => { 'defaults' => { 'default' => 'old' }, 'gc' => [] },
                  'run' => { 'key' => 'run' }, 'verified' => ['good'] }
      ImagePipeline::Publisher.new(summary, control).publish(source_dir: '.')
      expect(calls.map(&:first)).to eq(%w[status publish status publish])
      expect(calls.last.last).to eq('generation' => 'fresh', 'items' => [], 'superseded' => ['good'],
                                    'defaults' => {}, 'gc' => [], 'ancestors' => [])
    end
  end

  describe ImagePipeline::Control do
    %w[conflict superseded].each do |code|
      it "decodes #{code} from an actual nonzero ctl process and retains the response receipt" do
        with_tmpdir do |dir|
          response = { 'ok' => false, 'error' => { 'code' => code, 'message' => 'service rejected request' } }
          child = "STDIN.read; puts #{JSON.generate(response).dump}; warn 'ctl rejected request'; exit 1"
          allow(Open3).to receive(:popen3).and_wrap_original do |original, *command, &block|
            expect(command.first).to eq('ssh')
            original.call(RbConfig.ruby, '-e', child, &block)
          end
          control = described_class.new('producer@example', repository: 'vpsadminos', receipts: dir)
          expect { control.call('publish') }.to raise_error(ImagePipeline::ControlError) { |error| expect(error.code).to eq(code) }
          receipt = Dir.glob(File.join(dir, '*.response.json')).fetch(0)
          expect(JSON.parse(File.read(receipt))).to eq(response)
        end
      end
    end

    it 'retains SSH exit/stderr diagnostics for non-JSON failure without exposing stdout as a service error' do
      with_tmpdir do |dir|
        child = "STDIN.read; puts 'untrusted stdout'; warn 'permission denied'; exit 255"
        allow(Open3).to receive(:popen3).and_wrap_original do |original, *, &block|
          original.call(RbConfig.ruby, '-e', child, &block)
        end
        control = described_class.new('producer@example', repository: 'vpsadminos', receipts: dir)
        expect { control.call('status') }.to raise_error(RuntimeError) do |error|
          expect(error.message).to include('SSH control failed', 'exit 255', 'permission denied')
          expect(error.message).not_to include('untrusted stdout')
        end
      end
    end

    it 'does not accept a successful JSON result when SSH exits nonzero' do
      with_tmpdir do |dir|
        allow(Open3).to receive(:popen3).and_wrap_original do |original, *, &block|
          original.call(RbConfig.ruby, '-e', 'STDIN.read; puts %q({"ok":true,"result":{}}); exit 255', &block)
        end
        control = described_class.new('producer@example', repository: 'vpsadminos', receipts: dir)
        expect { control.call('status') }.to raise_error(RuntimeError, /SSH control failed.*exit 255/)
      end
    end
  end

  describe ImagePipeline::Selection do
    let(:items) { [{ 'id' => 'configured', 'name' => 'alpine-3.24' }] }

    it 'requests full CI weekly or on explicit manual selection, never for pushes' do
      expect(described_class.full_ci_requested?(event: 'schedule', requested: false)).to be(true)
      expect(described_class.full_ci_requested?(event: 'workflow_dispatch', requested: true)).to be(true)
      expect(described_class.full_ci_requested?(event: 'workflow_dispatch', requested: false)).to be(false)
      expect(described_class.full_ci_requested?(event: 'push', requested: false)).to be(false)
      expect(described_class.full_ci_requested?(event: 'push', requested: true)).to be(false)
    end

    it 'wires optional full CI independently from publication and retains the relocated specs in CI' do
      workflow = YAML.load_file(File.join(REPO_ROOT, '.github/workflows/image-scripts.yml'))
      triggers = workflow.fetch('on') { workflow.fetch(true) }
      expect(triggers.fetch('schedule')).to eq([{ 'cron' => '0 4 * * 0' }])
      expect(triggers.fetch('workflow_dispatch').fetch('inputs').fetch('full_ci'))
        .to include('type' => 'boolean', 'default' => false)
      jobs = workflow.fetch('jobs')
      expect(jobs.fetch('full-ci').fetch('if')).to include("needs.build.outputs.ci_ready == 'true'")
      expect(jobs.fetch('publish').fetch('needs')).to eq('build')
      expect(jobs.fetch('publish').fetch('if')).not_to include('ci_ready', 'sealed', 'success()')
      build = jobs.fetch('build').fetch('steps').find { |step| step['name'] == 'Build and verify selected images in warm workers' }
      expect(build.fetch('env').fetch('FULL_CI'))
        .to eq("${{ github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && inputs.full_ci) }}")
      expect(build.fetch('run')).to include('ci_args+=(--full-ci)', '"${ci_args[@]}"')
      runner = File.read(File.join(REPO_ROOT, '.github/workflows/scripts/run-rspec-all.sh'))
      expect(runner).to include('"image-pipeline:osvm"', 'spec_args=("${workspace}/tools/image-pipeline/spec")')
      rspec = YAML.load_file(File.join(REPO_ROOT, '.github/workflows/rspec.yml'))
      rspec.fetch('on') { rspec.fetch(true) }.each_value do |trigger|
        expect(trigger.fetch('paths')).to include('tools/image-pipeline/**')
      end
    end

    it 'intersects automatic source-image names with the configured plan' do
      expect(described_class.items(items, names: 'devuan-4,alpine-3.24', automatic: true)).to eq(items)
    end

    it 'rejects unknown manual selection instead of silently dropping it' do
      expect { described_class.items(items, names: 'devuan-4', automatic: false) }.to raise_error(/unknown selected images/)
    end

    it 'skips an empty automatic selection before opening a candidate run' do
      with_tmpdir do |dir|
        plan = File.join(dir, 'plan.json')
        graph = File.join(dir, 'inputs.json')
        state = File.join(dir, 'state')
        File.write(plan, JSON.generate('items' => items))
        File.write(graph, '{}')
        output, status = Open3.capture2e(RbConfig.ruby, File.join(REPO_ROOT, 'tools/image-pipeline/build.rb'),
                                         '--source-dir', REPO_ROOT, '--state-dir', state, '--plan', plan,
                                         '--input-graph', graph, '--event', 'push', '--ref', 'refs/heads/staging',
                                         '--images', 'devuan-4')
        expect(status.success?).to be(true)
        expect(output).to include('skipping candidate run')
        expect(File.exist?(File.join(state, 'run.json'))).to be(false)
      end
    end

    it 'rebuilds configured images when shared image tests change' do
      with_tmpdir do |dir|
        git = File.join(dir, 'git')
        File.write(git, "#!/bin/sh\nif [ \"$1\" = diff ]; then printf '%s\\n' image-scripts/tests/start.sh; fi\n")
        File.chmod(0o755, git)
        env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'BASE_SHA' => 'a' * 40, 'HEAD_SHA' => 'b' * 40,
                'DEFAULT_BRANCH' => 'staging', 'CURRENT_BRANCH' => 'staging' }
        output, status = Open3.capture2(env, RbConfig.ruby,
                                        File.join(REPO_ROOT, '.github/workflows/scripts/changed-image-scripts.rb'),
                                        chdir: REPO_ROOT, err: File::NULL)
        expect(status.success?).to be(true)
        expect(output.split(',')).to include('devuan-4')
        expect(described_class.items(items, names: output.strip, automatic: true)).to eq(items)
      end
    end
  end
end
