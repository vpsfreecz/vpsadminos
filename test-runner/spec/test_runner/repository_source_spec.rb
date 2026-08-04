# frozen_string_literal: true

require 'spec_helper'

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

  it 'keeps one immutable source while the checkout changes' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |root_directory|
        write_flake(repo)

        open_source(repo, root_directory) do |source|
          expect(source.path).to start_with('/nix/store/')
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
