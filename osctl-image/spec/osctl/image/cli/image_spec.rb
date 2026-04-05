# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Cli::Image do
  subject(:command) { build_command(described_class, opts:, args:, gopts:) }

  let(:opts) do
    {
      jobs: 1,
      rebuild: false,
      'skip-tests' => false,
      'keep-failed' => false,
      'output-dir' => '/output',
      'build-dataset' => 'tank/builds',
      tag: []
    }
  end
  let(:args) { [] }
  let(:gopts) { {} }

  def flow_command(args:, opts:, gopts: {})
    klass = Class.new(described_class) do
      attr_writer :image_list_override, :select_images_result, :select_tests_result,
                  :build_images_result, :test_images_result,
                  :process_test_results_result, :build_scripts_path_override,
                  :vpsadminos_dir_override, :unchanged_result
      attr_reader :processed_build_results_arg, :processed_test_results_arg

      def image_list
        return @image_list_override if instance_variable_defined?(:@image_list_override)

        super
      end

      def select_images(*)
        return @select_images_result if instance_variable_defined?(:@select_images_result)

        super
      end

      def select_tests(*)
        return @select_tests_result if instance_variable_defined?(:@select_tests_result)

        super
      end

      def build_images(*, **)
        return @build_images_result if instance_variable_defined?(:@build_images_result)

        super
      end

      def test_images(images, tests, rebuild: nil)
        if @test_images_result.respond_to?(:call)
          @test_images_result.call(images, tests, rebuild:)
        elsif instance_variable_defined?(:@test_images_result)
          @test_images_result
        else
          super
        end
      end

      def process_build_results(results)
        @processed_build_results_arg = results
      end

      def process_test_results(results)
        @processed_test_results_arg = results

        if instance_variable_defined?(:@process_test_results_result)
          @process_test_results_result
        else
          super
        end
      end

      def build_scripts_path
        return @build_scripts_path_override if instance_variable_defined?(:@build_scripts_path_override)

        super
      end

      def vpsadminos_dir
        return @vpsadminos_dir_override if instance_variable_defined?(:@vpsadminos_dir_override)

        super
      end

      def image_in_repo_unchanged?(build, repo)
        if @unchanged_result.respond_to?(:call)
          @unchanged_result.call(build, repo)
        elsif instance_variable_defined?(:@unchanged_result)
          @unchanged_result
        else
          super
        end
      end
    end

    build_command(klass, args:, opts:, gopts:)
  end

  describe '#list' do
    it 'prints the supported output fields' do
      output = capture_stdout { build_command(described_class, opts: { list: true }).list }

      expect(output).to eq("#{described_class::FIELDS.join("\n")}\n")
    end

    it 'loads image configs and prints them using the default columns' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)
        cmd = build_command(described_class, opts:, gopts: { 'build-scripts' => dir })
        image = instance_double(
          OsCtl::Image::Image,
          load_config: nil,
          name: 'alpine',
          distribution: 'alpine',
          version: '3.20',
          arch: 'x86_64',
          vendor: 'vendor',
          variant: 'minimal'
        )

        allow(OsCtl::Image::ImageList).to receive(:new).with(dir).and_return([image])
        allow(OsCtl::Lib::Cli::OutputFormatter).to receive(:print)

        cmd.list

        expect(OsCtl::Lib::Cli::OutputFormatter).to have_received(:print).with(
          [
            {
              name: 'alpine',
              distribution: 'alpine',
              version: '3.20',
              arch: 'x86_64',
              vendor: 'vendor',
              variant: 'minimal'
            }
          ],
          layout: :columns,
          cols: described_class::FIELDS,
          sort: nil,
          header: true
        )
      end
    end

    it 'appends sort columns to the selected output list when needed' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)
        cmd = build_command(
          described_class,
          opts: { output: 'name', sort: 'version' },
          gopts: { 'build-scripts' => dir }
        )
        image = instance_double(
          OsCtl::Image::Image,
          load_config: nil,
          name: 'alpine',
          distribution: 'alpine',
          version: '3.20',
          arch: 'x86_64',
          vendor: 'vendor',
          variant: 'minimal'
        )

        allow(OsCtl::Image::ImageList).to receive(:new).with(dir).and_return([image])
        allow(OsCtl::Lib::Cli::OutputFormatter).to receive(:print)

        cmd.list

        expect(OsCtl::Lib::Cli::OutputFormatter).to have_received(:print).with(
          anything,
          layout: :columns,
          cols: %i[name version],
          sort: [:version],
          header: true
        )
      end
    end
  end

  describe 'selection helpers' do
    it 'selects all images for the special all keyword' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)
        cmd = build_command(described_class, gopts: { 'build-scripts' => dir })
        image_a = instance_double(OsCtl::Image::Image, name: 'alpine')
        image_b = instance_double(OsCtl::Image::Image, name: 'debian')

        allow(OsCtl::Image::ImageList).to receive(:new).with(dir).and_return([image_a, image_b])

        expect(cmd.send(:select_images, 'all')).to eq([image_a, image_b])
      end
    end

    it 'selects explicit image names from a comma-separated list' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)
        cmd = build_command(described_class, gopts: { 'build-scripts' => dir })
        image_a = instance_double(OsCtl::Image::Image, name: 'alpine')
        image_b = instance_double(OsCtl::Image::Image, name: 'debian')

        allow(OsCtl::Image::ImageList).to receive(:new).with(dir).and_return([image_a, image_b])

        expect(cmd.send(:select_images, 'debian,alpine')).to eq([image_b, image_a])
      end
    end

    it 'raises on unknown image names' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)
        cmd = build_command(described_class, gopts: { 'build-scripts' => dir })
        image_a = instance_double(OsCtl::Image::Image, name: 'alpine')

        allow(OsCtl::Image::ImageList).to receive(:new).with(dir).and_return([image_a])

        expect { cmd.send(:select_images, 'missing') }
          .to raise_error(GLI::BadCommandLine, "image 'missing' not found")
      end
    end

    it 'selects all tests for nil or all' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)
        cmd = build_command(described_class, gopts: { 'build-scripts' => dir })
        test_a = instance_double(OsCtl::Image::Test, name: 'smoke')
        test_b = instance_double(OsCtl::Image::Test, name: 'upgrade')

        allow(OsCtl::Image::TestList).to receive(:new).with(dir).and_return([test_a, test_b])

        expect(cmd.send(:select_tests, nil)).to eq([test_a, test_b])
        expect(cmd.send(:select_tests, 'all')).to eq([test_a, test_b])
      end
    end

    it 'selects explicit tests from a comma-separated list' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)
        cmd = build_command(described_class, gopts: { 'build-scripts' => dir })
        test_a = instance_double(OsCtl::Image::Test, name: 'smoke')
        test_b = instance_double(OsCtl::Image::Test, name: 'upgrade')

        allow(OsCtl::Image::TestList).to receive(:new).with(dir).and_return([test_a, test_b])

        expect(cmd.send(:select_tests, 'upgrade,smoke')).to eq([test_b, test_a])
      end
    end

    it 'raises on unknown test names' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)
        cmd = build_command(described_class, gopts: { 'build-scripts' => dir })
        test_a = instance_double(OsCtl::Image::Test, name: 'smoke')

        allow(OsCtl::Image::TestList).to receive(:new).with(dir).and_return([test_a])

        expect { cmd.send(:select_tests, 'missing') }
          .to raise_error(GLI::BadCommandLine, "test 'missing' not found")
      end
    end
  end

  describe 'build scripts path detection' do
    it 'uses an explicit --build-scripts path when valid' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)

        path = build_command(described_class, gopts: { 'build-scripts' => dir }).send(:build_scripts_path)

        expect(path).to eq(dir)
      end
    end

    it 'uses the current working directory when it matches the interface' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)
        allow(Dir).to receive(:pwd).and_return(dir)

        expect(command.send(:build_scripts_path)).to eq(dir)
      end
    end

    it 'falls back to the built-in build scripts directory' do
      Dir.mktmpdir do |dir|
        create_build_scripts_dir(dir)
        stub_const("#{described_class}::BUILD_SCRIPTS_DIR", dir)
        allow(Dir).to receive(:pwd).and_return('/missing')

        expect(command.send(:build_scripts_path)).to eq(dir)
      end
    end

    it 'raises when no suitable build scripts directory is available' do
      stub_const("#{described_class}::BUILD_SCRIPTS_DIR", '/missing')
      allow(Dir).to receive(:pwd).and_return('/missing')

      expect { command.send(:build_scripts_path) }
        .to raise_error(GLI::BadCommandLine, 'Enter into build scripts directory or use option --build-scripts')
    end
  end

  describe 'vpsadminos checkout detection' do
    it 'accepts an explicit checkout path' do
      Dir.mktmpdir do |root|
        scripts_dir = File.join(root, 'scripts')
        create_build_scripts_dir(scripts_dir)
        create_fake_vpsadminos_checkout(root, scripts_dir:)

        path = build_command(
          described_class,
          gopts: {
            'build-scripts' => scripts_dir,
            'vpsadminos-dir' => root
          }
        ).send(:vpsadminos_dir)

        expect(path).to eq(File.realpath(root))
      end
    end

    it 'auto-detects the checkout by walking up from build scripts' do
      Dir.mktmpdir do |root|
        scripts_dir = File.join(root, 'nested', 'scripts')
        create_build_scripts_dir(scripts_dir)
        create_fake_vpsadminos_checkout(root, scripts_dir:)

        path = build_command(
          described_class,
          gopts: { 'build-scripts' => scripts_dir }
        ).send(:vpsadminos_dir)

        expect(path).to eq(root)
      end
    end

    it 'returns nil when no checkout is found automatically' do
      Dir.mktmpdir do |root|
        scripts_dir = File.join(root, 'scripts')
        create_build_scripts_dir(scripts_dir)

        path = build_command(
          described_class,
          gopts: { 'build-scripts' => scripts_dir }
        ).send(:vpsadminos_dir)

        expect(path).to be_nil
      end
    end

    it 'raises when the provided checkout is invalid' do
      Dir.mktmpdir do |root|
        invalid = File.join(root, 'invalid')
        scripts_dir = File.join(root, 'scripts')
        FileUtils.mkdir_p(invalid)
        create_build_scripts_dir(scripts_dir)

        expect do
          build_command(
            described_class,
            gopts: {
              'build-scripts' => scripts_dir,
              'vpsadminos-dir' => invalid
            }
          ).send(:vpsadminos_dir)
        end.to raise_error(GLI::BadCommandLine, "#{invalid.inspect} is not a vpsadminos checkout")
      end
    end

    it 'raises when the provided checkout does not exist' do
      expect do
        build_command(
          described_class,
          gopts: {
            'build-scripts' => '/scripts',
            'vpsadminos-dir' => '/missing'
          }
        ).send(:vpsadminos_dir)
      end.to raise_error(GLI::BadCommandLine, '"/missing" does not exist')
    end
  end

  describe 'build / test / instantiate / deploy flows' do
    it 'requires an image argument for build' do
      expect { command.build }.to raise_error(GLI::BadCommandLine)
    end

    it 'builds selected images and prints the results' do
      image = instance_double(OsCtl::Image::Image, name: 'alpine')
      build = instance_double(
        OsCtl::Image::Operations::Image::Build,
        image: image,
        output_tar: '/tmp/image-archive.tar',
        output_stream: '/tmp/image-stream.tar',
        image_attrs: {
          distribution: 'alpine',
          version: '3.20',
          arch: 'x86_64',
          vendor: 'override-vendor',
          variant: 'minimal'
        }
      )
      results = [OsCtl::Image::Operations::Execution::Parallel::Result.new(true, image, build, nil)]
      cmd = flow_command(args: ['alpine'], opts:)
      cmd.select_images_result = [image]
      cmd.build_images_result = [results, []]

      cmd.build

      expect(cmd.processed_build_results_arg).to eq(results)
    end

    it 'raises GLI::CustomExit when any selected test fails' do
      image = instance_double(OsCtl::Image::Image, name: 'alpine')
      failed = instance_double(OsCtl::Image::Operations::Test::Run::Status, success?: false)
      cmd = flow_command(args: %w[alpine smoke], opts:)
      cmd.select_images_result = [image]
      cmd.select_tests_result = [:smoke]
      cmd.test_images_result = [failed]
      cmd.process_test_results_result = [failed]

      expect { cmd.test }.to raise_error(GLI::CustomExit)
    end

    it 'instantiates a selected image and prints the resulting container id' do
      image = instance_double(OsCtl::Image::Image, name: 'alpine')
      cmd = flow_command(args: ['alpine'], opts:)
      cmd.image_list_override = [image]
      cmd.build_scripts_path_override = '/scripts'
      cmd.vpsadminos_dir_override = '/repo'
      allow(OsCtl::Image::Operations::Image::Instantiate).to receive(:run).and_return('ct123')

      output = capture_stdout { cmd.instantiate }

      expect(output).to eq("Container ID: ct123\n")
    end

    it 'raises when the named image is missing during instantiate' do
      image = instance_double(OsCtl::Image::Image, name: 'alpine')
      cmd = flow_command(args: ['missing'], opts:)
      cmd.image_list_override = [image]

      expect { cmd.instantiate }.to raise_error(RuntimeError, "image 'missing' not found")
    end

    it 'raises when there are no successful builds to test and deploy' do
      image = instance_double(OsCtl::Image::Image, name: 'alpine')
      cmd = flow_command(args: %w[all /repo], opts:)
      cmd.select_images_result = [image]
      cmd.build_images_result = [[], []]

      expect { cmd.deploy }.to raise_error(RuntimeError, 'no images to test and deploy')
    end

    it 'skips tests when requested and deploys successful and cached builds' do
      image = instance_double(OsCtl::Image::Image, name: 'alpine')
      build = instance_double(
        OsCtl::Image::Operations::Image::Build,
        image: image,
        output_tar: '/tmp/image-archive.tar',
        output_stream: '/tmp/image-stream.tar',
        image_attrs: {
          distribution: 'alpine',
          version: '3.20',
          arch: 'x86_64',
          vendor: 'override-vendor',
          variant: 'minimal'
        }
      )
      result = OsCtl::Image::Operations::Execution::Parallel::Result.new(true, image, build, nil)
      cached = instance_double(OsCtl::Image::Operations::Image::Build)
      cmd = flow_command(
        opts: opts.merge('skip-tests' => true, tag: %w[stable]),
        args: %w[all /repo]
      )
      cmd.select_images_result = [image]
      cmd.build_images_result = [[result], [cached]]
      allow(OsCtl::Image::Operations::Image::Deploy).to receive(:run)

      output = capture_stdout { cmd.deploy }

      expect(output).to include('Skipping tests')
      expect(OsCtl::Image::Operations::Image::Deploy).to have_received(:run).with(build, '/repo', tags: %w[stable])
      expect(OsCtl::Image::Operations::Image::Deploy).to have_received(:run).with(cached, '/repo', tags: %w[stable])
    end

    it 'prints no images to deploy when every successful build is unchanged' do
      image = instance_double(OsCtl::Image::Image, name: 'alpine')
      build = instance_double(
        OsCtl::Image::Operations::Image::Build,
        image: image,
        output_tar: '/tmp/image-archive.tar',
        output_stream: '/tmp/image-stream.tar',
        image_attrs: {
          distribution: 'alpine',
          version: '3.20',
          arch: 'x86_64',
          vendor: 'override-vendor',
          variant: 'minimal'
        }
      )
      result = OsCtl::Image::Operations::Execution::Parallel::Result.new(true, image, build, nil)
      cmd = flow_command(args: %w[all /repo], opts:)
      cmd.select_images_result = [image]
      cmd.build_images_result = [[result], []]
      cmd.unchanged_result = true
      allow(OsCtl::Image::TestList).to receive(:new).and_return([:smoke])
      cmd.build_scripts_path_override = '/scripts'
      allow(OsCtl::Image::Operations::Image::Deploy).to receive(:run)

      output = capture_stdout { cmd.deploy }

      expect(output).to include('no images to deploy')
      expect(OsCtl::Image::Operations::Image::Deploy).not_to have_received(:run)
    end

    it 'deploys only builds that pass their tests' do
      image = instance_double(OsCtl::Image::Image, name: 'alpine')
      build = instance_double(
        OsCtl::Image::Operations::Image::Build,
        image: image,
        output_tar: '/tmp/image-archive.tar',
        output_stream: '/tmp/image-stream.tar',
        image_attrs: {
          distribution: 'alpine',
          version: '3.20',
          arch: 'x86_64',
          vendor: 'override-vendor',
          variant: 'minimal'
        }
      )
      image2 = instance_double(OsCtl::Image::Image, name: 'debian')
      build2 = instance_double(OsCtl::Image::Operations::Image::Build, image: image2)
      success_status = instance_double(OsCtl::Image::Operations::Test::Run::Status, success?: true)
      failed_status = instance_double(
        OsCtl::Image::Operations::Test::Run::Status,
        success?: false,
        test: 'smoke',
        image: 'debian',
        exitstatus: 1,
        output: 'boom'
      )
      results = [
        OsCtl::Image::Operations::Execution::Parallel::Result.new(true, image, build, nil),
        OsCtl::Image::Operations::Execution::Parallel::Result.new(true, image2, build2, nil)
      ]
      cmd = flow_command(args: %w[all /repo], opts:)
      cmd.select_images_result = [image, image2]
      cmd.build_images_result = [results, []]
      cmd.unchanged_result = false
      allow(OsCtl::Image::TestList).to receive(:new).and_return([:smoke])
      cmd.build_scripts_path_override = '/scripts'
      cmd.test_images_result = lambda do |images, _tests, rebuild:|
        _rebuild = rebuild
        images.first == image ? [success_status] : [failed_status]
      end
      allow(OsCtl::Image::Operations::Image::Deploy).to receive(:run)

      cmd.deploy

      expect(OsCtl::Image::Operations::Image::Deploy).to have_received(:run).with(build, '/repo', tags: [])
      expect(OsCtl::Image::Operations::Image::Deploy).not_to have_received(:run).with(build2, '/repo', tags: [])
    end
  end

  describe '#image_in_repo_unchanged?' do
    it 'uses the effective build attrs when checking the repository' do
      build = instance_double(
        OsCtl::Image::Operations::Image::Build,
        image_attrs: {
          distribution: 'alpine',
          version: '3.20',
          arch: 'x86_64',
          vendor: 'override-vendor',
          variant: 'minimal'
        },
        output_stream: '/tmp/image-stream.tar'
      )
      allow(OsCtl::Image::Operations::Repository::GetImagePath).to receive(:run).and_return('/repo/image-stream.tar')
      allow(OsCtl::Image::Operations::File::Compare).to receive(:run).and_return(true)

      expect(command.send(:image_in_repo_unchanged?, build, '/repo')).to be(true)
      expect(OsCtl::Image::Operations::Repository::GetImagePath).to have_received(:run).with(
        '/repo',
        build.image_attrs,
        :zfs
      )
    end
  end

  describe 'result formatting helpers' do
    it 'prints build results for successful and failed builds' do
      success = OsCtl::Image::Operations::Execution::Parallel::Result.new(
        true,
        instance_double(OsCtl::Image::Image, name: 'alpine'),
        instance_double(
          OsCtl::Image::Operations::Image::Build,
          output_tar: '/tmp/alpine-archive.tar',
          output_stream: '/tmp/alpine-stream.tar'
        ),
        nil
      )
      failure = OsCtl::Image::Operations::Execution::Parallel::Result.new(
        false,
        instance_double(OsCtl::Image::Image, name: 'debian'),
        nil,
        RuntimeError.new('boom')
      )

      output = capture_stdout { command.send(:process_build_results, [success, failure]) }

      expect(output).to include('Build results:')
      expect(output).to include('alpine: /tmp/alpine-archive.tar')
      expect(output).to include('alpine: /tmp/alpine-stream.tar')
      expect(output).to include('debian: failed with RuntimeError: boom')
    end

    it 'returns an empty list when all tests succeed' do
      ok = instance_double(
        OsCtl::Image::Operations::Test::Run::Status,
        success?: true
      )

      output = capture_stdout do
        expect(command.send(:process_test_results, [ok, ok])).to eq([])
      end

      expect(output).to include('2 tests run, 2 succeeded, 0 failed')
    end

    it 'returns failed tests and prints their details' do
      failed = instance_double(
        OsCtl::Image::Operations::Test::Run::Status,
        success?: false,
        test: 'smoke',
        image: 'alpine',
        exitstatus: 2,
        output: "line 1\nline 2"
      )

      output = capture_stdout do
        expect(command.send(:process_test_results, [failed])).to eq([failed])
      end

      expect(output).to include('1 tests run, 0 succeeded, 1 failed')
      expect(output).to include('Failed tests:')
      expect(output).to include('Test smoke on alpine')
      expect(output).to include('line 1')
      expect(output).to include('line 2')
    end
  end
end
