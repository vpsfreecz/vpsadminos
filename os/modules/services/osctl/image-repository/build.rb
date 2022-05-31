#!@ruby@/bin/ruby
require 'fileutils'
require 'json'
require 'optparse'
require 'securerandom'

class Config
  JSON_CONFIG = '@json_config@'

  # @return [Array<Image>]
  attr_reader :images

  attr_reader :osctl_repo, :osctl_image

  def initialize
    @cfg = JSON.parse(File.read(JSON_CONFIG))

    @images = []

    @cfg['images'].each do |name, versions|
      versions.each do |version, image_opts|
        @images << Image.new(name, version, image_opts)
      end
    end

    @osctl_repo = File.join(@cfg['osctl_repo'], 'bin/osctl-repo')
    @osctl_image = File.join(@cfg['osctl_image'], 'bin/osctl-image')
  end

  %i(repo_dir cache_dir log_dir dataset script_dir default_vendor_variants
     default_vendor post_build gc).each do |m|
    define_method(m) { @cfg[m.to_s] }
  end

  %i(rebuild keep_failed_tests).each do |m|
    define_method(:"#{m}?") { @cfg[m.to_s] }
  end
end

class Image
  attr_reader :name, :tags

  def initialize(name, version, opts)
    @name = opts['name'] || "#{name}-#{version}"
    @version = version
    @opts = opts
    @tags = opts['tags']
  end

  def rebuild?
    @opts['rebuild']
  end

  def keep_failed_tests?
    @opts['keepFailedTests']
  end
end

class Builder
  def initialize
    @cfg = Config.new
  end

  def run
    options, names = parse_args

    ENV['NIX_PATH'] ||= "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos"

    # Initialize osctl-repo
    repo_init

    # Build & test & add images
    build_images(options, names)

    # Set default variants
    # Set default vendor
    repo_set_defaults

    # Run GC
    run_gc if cfg.gc

    # Run post build
    run_post_build
  end

  protected
  attr_reader :cfg

  def parse_args
    options = {}

    OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} [options] [image name...]"

      opts.on('-L', '--list', 'List images to build') do |v|
        cfg.images.each { |img| puts img.name }
        exit
      end

      opts.on('-R', '--[no-]rebuild', 'Rebuild images') do |v|
        options[:rebuild] = v
      end

      opts.on('-F', '--[no-]keep-failed-tests', 'Keep containers of failed tests') do |v|
        options[:keep_failed_tests] = v
      end

      opts.on('-S', '--skip-tests', 'Skip tests') do |v|
        options[:skip_tests] = true
      end
    end.parse!

    [options, ARGV]
  end

  def repo_init
    return if Dir.exist?(cfg.repo_dir) && !Dir.empty?(cfg.repo_dir)

    FileUtils.mkdir_p(cfg.repo_dir)

    with_repo_dir { osctl_repo('local', 'init') }
  end

  def build_images(options, names)
    FileUtils.mkdir_p(cfg.cache_dir)

    with_script_dir do
      cfg.images.each do |img|
        if names.any? && !names.include?(img.name)
          puts "Skipping #{img.name}"
          next
        end

        puts "Building #{img.name}"

        deploy_args = [
          'deploy',
          '--build-dataset', cfg.dataset,
          '--output-dir', cfg.cache_dir,
        ]

        if rebuild_image?(options, img)
          deploy_args << '--rebuild'
        end

        if keep_image_failed_tests?(options, img)
          deploy_args << '--keep-failed'
        end

        if options[:skip_tests]
          deploy_args << '--skip-tests'
        end

        deploy_args.concat(img.tags.map { |t| ['--tag', t] }.flatten)

        deploy_args << img.name
        deploy_args << cfg.repo_dir

        log_name = File.join(
          cfg.log_dir,
          "#{img.name}.#{Time.now.strftime('%Y-%m-%d-%H:%M:%S')}.#{SecureRandom.hex(3)}.log",
        )
        log_file = File.open(log_name, 'w')

        osctl_image(*deploy_args, out: log_file, err: log_file)
        log_file.close

        if $?.exitstatus == 0
          File.unlink(log_file.path)
        else
          warn "Build of #{img.name} failed with exit status #{$?.exitstatus}"
          warn "Log file: #{log_file.path}"
        end
      end
    end
  end

  def repo_set_defaults
    with_repo_dir do
      cfg.default_vendor_variants.each do |vendor, variant|
        osctl_repo('local', 'default', vendor, variant)
      end

      osctl_repo('local', 'default', cfg.default_vendor)
    end
  end

  def run_gc
    with_repo_dir do
      spawn_wait(*cfg.gc)

      if $?.exitstatus != 0
        warn "Garbage collector failed with exit status #{$?.exitstatus}"
      end
    end
  end

  def run_post_build
    with_repo_dir do
      spawn_wait(cfg.post_build)

      if $?.exitstatus != 0
        warn "Post build script failed with exit status #{$?.exitstatus}"
      end
    end
  end

  def rebuild_image?(options, img)
    if options.has_key?(:rebuild)
      options[:rebuild]
    else
      cfg.rebuild? || img.rebuild?
    end
  end

  def keep_image_failed_tests?(options, img)
    if options.has_key?(:keep_failed_tests)
      options[:keep_failed_tests]
    else
      cfg.keep_failed_tests? || img.keep_failed_tests?
    end
  end

  def with_repo_dir(&block)
    with_chdir(cfg.repo_dir, &block)
  end

  def with_script_dir(&block)
    with_chdir(cfg.script_dir, &block)
  end

  def with_chdir(dir)
    pwd = Dir.pwd
    Dir.chdir(dir)
    yield
    Dir.chdir(pwd)
  end

  def osctl_repo(*args, **kwargs)
    spawn_wait(cfg.osctl_repo, *args, **kwargs)
  end

  def osctl_image(*args, **kwargs)
    spawn_wait(cfg.osctl_image, *args, **kwargs)
  end

  def spawn_wait(*args, **kwargs)
    puts "> #{args.join(' ')}"
    pid = Process.spawn(*args, **kwargs)
    Process.wait(pid)
  end
end

builder = Builder.new
builder.run
