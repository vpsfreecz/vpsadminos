require 'json'

module OsCtl::Repo
  class Cli::Repo < Cli::Command
    def init
      repo = Local::Repository.new(Dir.pwd)
      fail 'repository already exists' if repo.exist?

      repo.create
    end

    def add
      require_args!('vendor', 'variant', 'arch', 'distribution', 'version')

      repo = Local::Repository.new(Dir.pwd)
      fail 'repository not found' unless repo.exist?

      vendor, variant, arch, distribution, version = args

      if vendor == 'default'
        raise GLI::BadCommandLine, 'unable to set vendor to default, name reserved'

      elsif variant == 'default'
        raise GLI::BadCommandLine, 'unable to set variant to default, name reserved'
      end

      rootfs = Hash[{
        tar: opts[:archive],
        zfs: opts[:stream],
      }.select{ |_, v| v }]

      if rootfs.empty?
        raise GLI::BadCommandLine, 'no rootfs, use --archive or --stream'
      end

      repo.add(
        vendor,
        variant,
        arch,
        distribution,
        version,
        tags: opts[:tag],
        rootfs: rootfs
      )
    end

    def set_default
      require_args!('vendor')

      repo = Local::Repository.new(Dir.pwd)
      fail 'repository not found' unless repo.exist?

      if args.count == 1
        repo.set_default_vendor(args[0])

      elsif args.count == 2
        repo.set_default_variant(args[0], args[1])

      else
        raise GLI::BadCommandLine, 'too many aguments'
      end
    end

    def rm
      require_args!('vendor', 'variant', 'arch', 'distribution', 'version')

      repo = Local::Repository.new(Dir.pwd)
      fail 'repository not found' unless repo.exist?

      tpl = repo.find(*args)
      fail 'template not found' unless tpl

      repo.remove(tpl)
    end

    def list
      require_args!('repo')

      repo = Remote::Repository.new(args[0])

      if opts[:cache]
        repo.path = opts[:cache]
        dl = Downloader::Cached.new(repo)
      else
        dl = Downloader::Direct.new(repo)
      end

      puts dl.list.map(&:dump).to_json
    end

    def fetch
      require_args!(
        'repo', 'vendor', 'variant', 'arch', 'distribution', 'version|tag',
        'tar|zfs'
      )

      repo = Remote::Repository.new(args[0])
      repo.path = opts[:cache]

      dl = Downloader::Cached.new(repo)
      dl.download(*args[1..-1])
    end

    def get
      require_args!(
        'repo', 'vendor', 'variant', 'arch', 'distribution', 'version|tag',
        'tar|zfs'
      )

      repo = Remote::Repository.new(args[0])

      if opts[:cache]
        repo.path = opts[:cache]
        dl = Downloader::Cached.new(repo)
      else
        dl = Downloader::Direct.new(repo)
      end

      dl.download(*args[1..-1]) do |fragment|
        STDOUT.write(fragment)
      end
    end
  end
end
