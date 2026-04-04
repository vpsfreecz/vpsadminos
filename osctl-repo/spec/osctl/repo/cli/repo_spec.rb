# frozen_string_literal: true

require 'osctl/repo'
require 'osctl/repo/cli'

RSpec.describe OsCtl::Repo::Cli::Repo do
  def build_command(opts: {}, args: [])
    described_class.new({}, opts, args)
  end

  def stub_local_repo(local_repo)
    allow(Dir).to receive(:pwd).and_return('/repo')
    allow(OsCtl::Repo::Local::Repository).to receive(:new)
      .with('/repo')
      .and_return(local_repo)
  end

  def stub_remote_repo(remote_repo)
    allow(OsCtl::Repo::Remote::Repository).to receive(:new)
      .with('https://repo.example')
      .and_return(remote_repo)
  end

  describe '#init' do
    it 'creates the repository' do
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: false, create: nil)
      stub_local_repo(local_repo)

      build_command.init

      expect(local_repo).to have_received(:create)
    end

    it 'rejects existing repositories' do
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true)
      stub_local_repo(local_repo)

      expect { build_command.init }.to raise_error(
        RuntimeError,
        'repository already exists'
      )
    end
  end

  describe '#local_list' do
    it 'prints a header and image rows' do
      image = instance_double(
        OsCtl::Repo::Base::Image,
        vendor: 'vendor',
        variant: 'variant',
        arch: 'x86_64',
        distribution: 'alpine',
        version: '3.20',
        tags: %w[stable current]
      )
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true, images: [image])
      stub_local_repo(local_repo)

      output = capture_stdout { build_command.local_list }

      expect(output).to include('VENDOR')
      expect(output).to include('vendor')
      expect(output).to include('stable,current')
    end
  end

  describe '#add' do
    it 'validates required arguments' do
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true, add: nil)
      stub_local_repo(local_repo)

      expect { build_command.add }.to raise_error(
        GLI::BadCommandLine,
        'missing argument <vendor>'
      )
    end

    it 'rejects the reserved default vendor name' do
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true, add: nil)
      stub_local_repo(local_repo)

      expect do
        build_command(args: %w[default variant x86_64 alpine 3.20]).add
      end.to raise_error(
        GLI::BadCommandLine,
        'unable to set vendor to default, name reserved'
      )
    end

    it 'rejects the reserved default variant name' do
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true, add: nil)
      stub_local_repo(local_repo)

      expect do
        build_command(args: %w[vendor default x86_64 alpine 3.20]).add
      end.to raise_error(
        GLI::BadCommandLine,
        'unable to set variant to default, name reserved'
      )
    end

    it 'rejects missing image files' do
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true, add: nil)
      stub_local_repo(local_repo)

      expect do
        build_command(args: %w[vendor variant x86_64 alpine 3.20]).add
      end.to raise_error(
        GLI::BadCommandLine,
        'no image, use --archive or --stream'
      )
    end

    it 'forwards tags and image paths to the repository' do
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true, add: nil)
      stub_local_repo(local_repo)

      build_command(
        opts: {
          tag: %w[stable current],
          archive: '/tmp/image.tar',
          stream: '/tmp/image.zfs'
        },
        args: %w[vendor variant x86_64 alpine 3.20]
      ).add

      expect(local_repo).to have_received(:add).with(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        '3.20',
        tags: %w[stable current],
        image: {
          tar: '/tmp/image.tar',
          zfs: '/tmp/image.zfs'
        }
      )
    end
  end

  describe '#local_get_path' do
    let(:args) { %w[vendor variant x86_64 alpine stable tar] }

    it 'prints the versioned image path' do
      image = instance_double(
        OsCtl::Repo::Base::Image,
        has_image?: true,
        version_image_path: 'v1/vendor/variant/x86_64/alpine/3.20/image-archive.tar'
      )
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true, find: image)
      stub_local_repo(local_repo)

      output = capture_stdout { build_command(args: args).local_get_path }

      expect(output).to eq("v1/vendor/variant/x86_64/alpine/3.20/image-archive.tar\n")
    end

    it 'errors when the image is missing' do
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true, find: nil)
      stub_local_repo(local_repo)

      expect { build_command(args: args).local_get_path }.to raise_error(
        RuntimeError,
        'image not found'
      )
    end

    it 'errors when the requested format is missing' do
      image = instance_double(
        OsCtl::Repo::Base::Image,
        has_image?: false,
        version_image_path: 'v1/vendor/variant/x86_64/alpine/3.20/image-archive.tar'
      )
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true, find: image)
      stub_local_repo(local_repo)

      expect { build_command(args: args).local_get_path }.to raise_error(
        RuntimeError,
        'image format not found'
      )
    end
  end

  describe '#set_default' do
    it 'dispatches to set_default_vendor for one argument' do
      local_repo = instance_double(
        OsCtl::Repo::Local::Repository,
        exist?: true,
        set_default_vendor: nil,
        set_default_variant: nil
      )
      stub_local_repo(local_repo)

      build_command(args: %w[vendor]).set_default

      expect(local_repo).to have_received(:set_default_vendor).with('vendor')
    end

    it 'dispatches to set_default_variant for two arguments' do
      local_repo = instance_double(
        OsCtl::Repo::Local::Repository,
        exist?: true,
        set_default_vendor: nil,
        set_default_variant: nil
      )
      stub_local_repo(local_repo)

      build_command(args: %w[vendor variant]).set_default

      expect(local_repo).to have_received(:set_default_variant).with('vendor', 'variant')
    end

    it 'rejects too many arguments' do
      local_repo = instance_double(
        OsCtl::Repo::Local::Repository,
        exist?: true,
        set_default_vendor: nil,
        set_default_variant: nil
      )
      stub_local_repo(local_repo)

      expect do
        build_command(args: %w[vendor variant extra]).set_default
      end.to raise_error(
        GLI::BadCommandLine,
        'unknown argument: extra'
      )
    end
  end

  describe '#rm' do
    let(:args) { %w[vendor variant x86_64 alpine 3.20] }

    it 'removes the selected image' do
      image = instance_double(OsCtl::Repo::Base::Image)
      local_repo = instance_double(
        OsCtl::Repo::Local::Repository,
        exist?: true,
        find: image,
        remove: nil
      )
      stub_local_repo(local_repo)

      build_command(args: args).rm

      expect(local_repo).to have_received(:remove).with(image)
    end

    it 'errors when the image is missing' do
      local_repo = instance_double(OsCtl::Repo::Local::Repository, exist?: true, find: nil)
      stub_local_repo(local_repo)

      expect { build_command(args: args).rm }.to raise_error(
        RuntimeError,
        'image not found'
      )
    end
  end

  describe '#remote_list' do
    let(:args) { ['https://repo.example'] }

    it 'uses the cached downloader when cache is configured' do
      remote_repo = instance_double(OsCtl::Repo::Remote::Repository)
      image = instance_double(OsCtl::Repo::Remote::Image, dump: { version: '3.20' })
      downloader = instance_double(OsCtl::Repo::Downloader::Cached, list: [image])
      stub_remote_repo(remote_repo)
      allow(remote_repo).to receive(:path=)
      allow(OsCtl::Repo::Downloader::Cached).to receive(:new)
        .with(remote_repo)
        .and_return(downloader)

      output = capture_stdout do
        build_command(opts: { cache: '/cache' }, args: args).remote_list
      end

      expect(remote_repo).to have_received(:path=).with('/cache')
      expect(output).to eq("[{\"version\":\"3.20\"}]\n")
    end

    it 'uses the direct downloader without cache' do
      remote_repo = instance_double(OsCtl::Repo::Remote::Repository)
      image = instance_double(OsCtl::Repo::Remote::Image, dump: { version: '3.20' })
      downloader = instance_double(OsCtl::Repo::Downloader::Direct, list: [image])
      stub_remote_repo(remote_repo)
      allow(OsCtl::Repo::Downloader::Direct).to receive(:new)
        .with(remote_repo)
        .and_return(downloader)

      output = capture_stdout { build_command(args: args).remote_list }

      expect(output).to eq("[{\"version\":\"3.20\"}]\n")
    end
  end

  describe '#fetch' do
    it 'uses the cached downloader with force_check enabled' do
      remote_repo = instance_double(OsCtl::Repo::Remote::Repository)
      downloader = instance_double(OsCtl::Repo::Downloader::Cached, get: '/cache/image.tar')
      stub_remote_repo(remote_repo)
      allow(remote_repo).to receive(:path=)
      allow(OsCtl::Repo::Downloader::Cached).to receive(:new)
        .with(remote_repo)
        .and_return(downloader)

      output = capture_stdout do
        build_command(
          opts: { cache: '/cache' },
          args: %w[https://repo.example vendor variant x86_64 alpine stable tar]
        ).fetch
      end

      expect(remote_repo).to have_received(:path=).with('/cache')
      expect(downloader).to have_received(:get).with(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        'stable',
        'tar',
        force_check: true
      )
      expect(output).to eq("/cache/image.tar\n")
    end
  end

  describe '#remote_get_path' do
    it 'passes force-check through to the downloader' do
      remote_repo = instance_double(OsCtl::Repo::Remote::Repository)
      downloader = instance_double(OsCtl::Repo::Downloader::Cached, get: '/cache/image.tar')
      stub_remote_repo(remote_repo)
      allow(remote_repo).to receive(:path=)
      allow(OsCtl::Repo::Downloader::Cached).to receive(:new)
        .with(remote_repo)
        .and_return(downloader)

      output = capture_stdout do
        build_command(
          opts: { cache: '/cache', 'force-check' => true },
          args: %w[https://repo.example vendor variant x86_64 alpine stable tar]
        ).remote_get_path
      end

      expect(downloader).to have_received(:get).with(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        'stable',
        'tar',
        force_check: true
      )
      expect(output).to eq("/cache/image.tar\n")
    end
  end

  describe '#remote_get_stream' do
    it 'writes streamed fragments to stdout' do
      remote_repo = instance_double(OsCtl::Repo::Remote::Repository)
      downloader = instance_double(OsCtl::Repo::Downloader::Direct)
      stub_remote_repo(remote_repo)
      allow(OsCtl::Repo::Downloader::Direct).to receive(:new)
        .with(remote_repo)
        .and_return(downloader)
      allow(downloader).to receive(:get) do |*_args, &block|
        block.call('chunk-one')
        block.call('chunk-two')
      end

      output = capture_stdout do
        build_command(
          args: %w[https://repo.example vendor variant x86_64 alpine stable tar]
        ).remote_get_stream
      end

      expect(downloader).to have_received(:get).with(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        'stable',
        'tar',
        force_check: nil
      )
      expect(output).to eq('chunk-onechunk-two')
    end
  end
end
