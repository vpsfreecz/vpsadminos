# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

RSpec.describe TestRunner::RepositorySource do
  def open_source(repo, root_directory, &)
    described_class.open(
      original_path: repo,
      root_directory:,
      nixpkgs_path: ENV.fetch('TEST_RUNNER_NIXPKGS_PATH'),
      nix_system: ENV.fetch('TEST_RUNNER_NIX_SYSTEM'),
      &
    )
  end

  def write_flake(repo)
    File.write(
      File.join(repo, 'flake.nix'),
      <<~NIX
        {
          inputs = { };
          outputs = { self }: { };
        }
      NIX
    )
    File.write(File.join(repo, 'marker'), "before\n")
  end

  def git(repo, *args)
    out, err, status = Open3.capture3('git', '-C', repo, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  def commit_fixture(repo)
    Tempfile.create('source-commit-') do |message|
      message.write("Capture fixture content\n")
      message.flush
      git(repo, '-c', 'user.name=Source fixture', '-c', 'user.email=fixture@example.test', 'commit', '-q', '-F', message.path)
    end
    git(repo, 'rev-parse', 'HEAD')
  end

  def git_fixture(repo)
    write_flake(repo)
    File.write(File.join(repo, '.gitignore'), "ignored\n")
    git(repo, 'init', '-q')
    git(repo, 'add', '.')
    commit_fixture(repo)
  end

  [false, true].each do |worktree|
    it "captures clean Git identity with linked worktree=#{worktree}" do
      Dir.mktmpdir do |dir|
        repo = File.join(dir, 'repo')
        FileUtils.mkdir_p(repo)
        revision = git_fixture(repo)
        if worktree
          linked = File.join(dir, 'linked')
          git(repo, 'worktree', 'add', '-q', '-b', 'linked', linked)
          repo = linked
        end
        index = git(repo, 'rev-parse', '--path-format=absolute', '--git-path', 'index')
        original_index = File.binread(index)

        open_source(repo, File.join(dir, 'roots')) do |source|
          expect(source.source_info).to eq(sourcePath: source.path, revision:, shortRev: revision[0, 7], dirty: false)
          expect(File.binread(index)).to eq(original_index)

          File.write(File.join(repo, 'marker'), "later\n")
          git(repo, 'add', 'marker')
          commit_fixture(repo)
          expect(source.source_info.fetch(:revision)).to eq(revision)
          expect(source.source_info.fetch(:dirty)).to be(false)
          expect(File.read(File.join(source.path, 'marker'))).to eq("before\n")
        end
        expect(Dir.children(File.join(dir, 'roots'))).to be_empty
      end
    end
  end

  it 'compares captured tracked, untracked and ignored content without modifying the caller index' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |roots|
        revision = git_fixture(repo)
        File.write(File.join(repo, 'marker'), "staged\n")
        git(repo, 'add', 'marker')
        File.write(File.join(repo, 'marker'), "captured\n")
        File.write(File.join(repo, 'untracked'), "included\n")
        File.write(File.join(repo, 'ignored'), "included despite ignore\n")
        index = File.join(repo, '.git/index')
        original_index = File.binread(index)

        open_source(repo, roots) do |source|
          expect(source.source_info).to include(revision:, dirty: true)
          expect(File.read(File.join(source.path, 'marker'))).to eq("captured\n")
          expect(File.read(File.join(source.path, 'untracked'))).to eq("included\n")
          expect(File.read(File.join(source.path, 'ignored'))).to eq("included despite ignore\n")
          expect(File.binread(index)).to eq(original_index)
        end
      end
    end
  end

  %w[untracked ignored].each do |name|
    it "marks included #{name} content dirty even without tracked changes" do
      Dir.mktmpdir do |repo|
        Dir.mktmpdir do |roots|
          git_fixture(repo)
          File.write(File.join(repo, name), "extra\n")
          open_source(repo, roots) { |source| expect(source.source_info.fetch(:dirty)).to be(true) }
        end
      end
    end
  end

  it 'compares the snapshot against the commit captured before resolution, not a later HEAD' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |roots|
        revision = git_fixture(repo)
        source = described_class.new(original_path: repo, root_directory: roots)
        allow(source).to receive(:resolve_and_root_source).and_wrap_original do |resolve, *args|
          File.write(File.join(repo, 'marker'), "new commit\n")
          git(repo, 'add', 'marker')
          commit_fixture(repo)
          resolve.call(*args)
        end
        source.open do
          expect(source.source_info).to include(revision:, dirty: true)
          expect(File.read(File.join(source.path, 'marker'))).to eq("new commit\n")
        end
      end
    end
  end

  it 'does not attribute a Git-free child source to its parent repository' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |roots|
        git_fixture(repo)
        child = File.join(repo, 'child')
        FileUtils.mkdir_p(child)
        write_flake(child)
        open_source(child, roots) do |source|
          expect(source.source_info).to eq(sourcePath: source.path, revision: nil, shortRev: nil, dirty: nil)
        end
      end
    end
  end

  it 'keeps one immutable source while the checkout changes' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |root_directory|
        write_flake(repo)

        open_source(repo, root_directory) do |source|
          expect(source.path).to start_with('/nix/store/')
          expect(source.source_info).to include(revision: nil, dirty: nil)
          expect(File.read(File.join(source.path, 'marker'))).to eq("before\n")
          expect(Dir.glob(File.join(root_directory, '*.root')).length).to eq(1)

          File.write(File.join(repo, 'marker'), "after\n")
          File.write(File.join(repo, 'test.log'), "growing output\n")

          expect(File.read(File.join(source.path, 'marker'))).to eq("before\n")
          expect(File).not_to exist(File.join(source.path, 'test.log'))
        end

        expect(Dir.glob(File.join(root_directory, '*'))).to be_empty
      end
    end
  end

  it 'removes the GC root when the command raises' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |root_directory|
        write_flake(repo)

        expect do
          open_source(repo, root_directory) do
            raise 'command failed'
          end
        end.to raise_error(RuntimeError, 'command failed')

        expect(Dir.glob(File.join(root_directory, '*'))).to be_empty
      end
    end
  end

  it 'removes abandoned roots without disturbing a live invocation' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |root_directory|
        write_flake(repo)

        open_source(repo, root_directory) do |first|
          File.write(File.join(root_directory, 'abandoned.lock'), '')
          File.symlink(first.path, File.join(root_directory, 'abandoned.root'))

          open_source(repo, root_directory) do
            expect(File).not_to exist(File.join(root_directory, 'abandoned.lock'))
            expect(File).not_to exist(File.join(root_directory, 'abandoned.root'))
            expect(Dir.glob(File.join(root_directory, '*.root')).length).to eq(2)
          end
        end

        expect(Dir.glob(File.join(root_directory, '*'))).to be_empty
      end
    end
  end

  it 'scavenges a root abandoned by a killed invocation' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |root_directory|
        write_flake(repo)
        reader, writer = IO.pipe

        pid = Process.fork do
          reader.close
          open_source(repo, root_directory) do
            writer.puts('ready')
            writer.close
            Process.exit!(0)
          end
        end

        writer.close
        expect(reader.gets).to eq("ready\n")
        reader.close
        Process.wait(pid)
        expect($?.exitstatus).to eq(0)
        expect(Dir.glob(File.join(root_directory, '*.lock')).length).to eq(1)
        expect(Dir.glob(File.join(root_directory, '*.root')).length).to eq(1)

        open_source(repo, root_directory) do
          expect(Dir.glob(File.join(root_directory, '*.lock')).length).to eq(1)
          expect(Dir.glob(File.join(root_directory, '*.root')).length).to eq(1)
        end

        expect(Dir.glob(File.join(root_directory, '*'))).to be_empty
      end
    end
  end

  it 'keeps concurrent invocation roots separate and live' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |root_directory|
        write_flake(repo)
        ready = Queue.new
        release = Queue.new

        threads = 2.times.map do
          Thread.new do
            open_source(repo, root_directory) do |source|
              ready << source.path
              release.pop
            end
          end
        end

        paths = 2.times.map { ready.pop }
        expect(paths.uniq.length).to eq(1)
        expect(Dir.glob(File.join(root_directory, '*.lock')).length).to eq(2)
        expect(Dir.glob(File.join(root_directory, '*.root')).length).to eq(2)

        2.times { release << true }
        threads.each(&:value)

        expect(Dir.glob(File.join(root_directory, '*'))).to be_empty
      end
    end
  end

  it 'maps repository config paths into the immutable source' do
    source = described_class.new(
      original_path: '/work/repo',
      root_directory: '/tmp/source-roots',
      nixpkgs_path: '/nix/store/nixpkgs',
      nix_system: 'x86_64-linux'
    )
    source.instance_variable_set(:@path, '/nix/store/source')

    expect(source.resolve_path('tests/config.nix')).to eq('/nix/store/source/tests/config.nix')
    expect(source.resolve_path('/work/repo/tests/config.nix')).to eq('/nix/store/source/tests/config.nix')
    expect(source.resolve_path('/etc/test-config.nix')).to eq('/etc/test-config.nix')
  end
end
