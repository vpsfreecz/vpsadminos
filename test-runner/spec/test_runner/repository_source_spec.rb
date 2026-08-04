# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::RepositorySource do
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
      Dir.mktmpdir do |state_dir|
        write_flake(repo)

        described_class.open(original_path: repo, state_dir:) do |source|
          expect(source.path).to start_with('/nix/store/')
          expect(File.read(File.join(source.path, 'marker'))).to eq("before\n")
          expect(Dir.glob(File.join(state_dir, '.repository-sources', '*.root')).length).to eq(1)

          File.write(File.join(repo, 'marker'), "after\n")
          File.write(File.join(repo, 'test.log'), "growing output\n")

          expect(File.read(File.join(source.path, 'marker'))).to eq("before\n")
          expect(File).not_to exist(File.join(source.path, 'test.log'))
        end

        expect(Dir.glob(File.join(state_dir, '.repository-sources', '*'))).to be_empty
      end
    end
  end

  it 'removes the GC root when the command raises' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |state_dir|
        write_flake(repo)

        expect do
          described_class.open(original_path: repo, state_dir:) do
            raise 'command failed'
          end
        end.to raise_error(RuntimeError, 'command failed')

        expect(Dir.glob(File.join(state_dir, '.repository-sources', '*'))).to be_empty
      end
    end
  end

  it 'removes abandoned roots without disturbing a live invocation' do
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |state_dir|
        write_flake(repo)
        root_dir = File.join(state_dir, '.repository-sources')

        described_class.open(original_path: repo, state_dir:) do |first|
          File.write(File.join(root_dir, 'abandoned.lock'), '')
          File.symlink(first.path, File.join(root_dir, 'abandoned.root'))

          described_class.open(original_path: repo, state_dir:) do
            expect(File).not_to exist(File.join(root_dir, 'abandoned.lock'))
            expect(File).not_to exist(File.join(root_dir, 'abandoned.root'))
            expect(Dir.glob(File.join(root_dir, '*.root')).length).to eq(2)
          end
        end
      end
    end
  end

  it 'maps repository config paths into the immutable source' do
    source = described_class.new(original_path: '/work/repo', state_dir: '/tmp/state')
    source.instance_variable_set(:@path, '/nix/store/source')

    expect(source.resolve_path('tests/config.nix')).to eq('/nix/store/source/tests/config.nix')
    expect(source.resolve_path('/work/repo/tests/config.nix')).to eq('/nix/store/source/tests/config.nix')
    expect(source.resolve_path('/etc/test-config.nix')).to eq('/etc/test-config.nix')
  end
end
