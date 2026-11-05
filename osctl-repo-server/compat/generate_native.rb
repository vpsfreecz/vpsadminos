# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# Exercise the real Ruby CLI and the real GC program. No catalog, alias or
# retention algorithm is implemented by this generator.
module NativeOracle
  ROOT = File.expand_path('../..', __dir__)
  FIXTURES = File.join(ROOT, 'osctl-repo-server/testdata/native')
  GC_SOURCE = 'os/modules/services/osctl/image-repository/gc.rb'
  SOURCE_FILES = [
    GC_SOURCE,
    'os/configs/image-repository.nix',
    'osctl-repo/lib/osctl/repo/base/image.rb',
    'osctl-repo/lib/osctl/repo/local/index.rb',
    'osctl-repo/lib/osctl/repo/local/repository.rb',
    'osctl-repo/lib/osctl/repo/cli/repo.rb'
  ].freeze

  def self.configured_gc
    text = File.read(File.join(ROOT, 'os/configs/image-repository.nix'))
    body = text.split('garbageCollection = [', 2).fetch(1).split('];', 2).fetch(0)
    body.scan(/\{([^}]+)\}/m).flatten.map do |block|
      fields = /(\w+)\s*=\s*("(?:\\.|[^"])*"|\d+)\s*;/
      raise 'Unsupported configured GC expression' unless block.gsub(fields, '').strip.empty?

      block.scan(fields).each_with_object({}) do |(key, value), rule|
        decoded = JSON.parse(value)
        rule[key] = decoded
      end
    end
  end

  def self.image(distribution, version, variant: 'minimal', vendor: 'vpsadminos',
                 arch: 'x86_64', tags: [], formats: %w[tar zfs])
    { 'tuple' => [vendor, variant, arch, distribution, version],
      'tags' => tags, 'formats' => formats }
  end

  def self.scenarios
    arch = %w[9 10 11 12 13].map { |v| image('arch', v) }
    {
      'catalog' => {
        'baseline' => [
          image('debian', '13', tags: %w[latest stable]),
          image('debian', '12', tags: %w[oldstable]),
          image('debian', '11', tags: %w[oldstable oldoldstable]),
          image('nixos', '26.05', variant: 'impermanence', formats: %w[zfs]),
          image('nixos', '26.05', tags: %w[stable]),
          image('alpine', '3.9', vendor: 'other', arch: 'aarch64', formats: %w[tar])
        ],
        'updates' => [], 'failed' => [], 'gc' => []
      },
      'gc' => {
        'baseline' => arch + %w[1 2 3 4 5].map { |v| image('arch', v, variant: 'full') } +
          %w[minimal impermanence].flat_map do |variant|
            %w[1 2 3 4 5].map { |v| image('nixos', "unstable-#{v}", variant: variant) }
          end + [image('nixos', '26.05'), image('alpine', '3.22'),
                 image('arch', '1', arch: 'aarch64'), image('arch', '1', vendor: 'other')],
        'updates' => [], 'failed' => [],
        # The catch-all intentionally overlaps: the first rule must win.
        'gc' => configured_gc + [{ 'distribution' => '^arch$', 'version' => '^\\d+$', 'keep' => 0 }]
      },
      'subset' => {
        'baseline' => arch + [image('alpine', '3.21')],
        'updates' => [image('alpine', '3.22', tags: %w[latest])], 'failed' => [],
        'gc' => [{ 'distribution' => 'arch', 'version' => '^\\d+$', 'keep' => 4 }]
      },
      'mixed_failure' => {
        'baseline' => arch + [image('debian', '12', tags: %w[oldstable])] +
          %w[1 2 3 4].map { |v| image('centos', "9-stream-#{v}") },
        'updates' => [image('debian', '13', tags: %w[latest stable])],
        'failed' => [image('arch', '14'), image('centos', '9-stream-5')],
        'gc' => configured_gc
      }
    }
  end

  def self.run(cli, *args, chdir:)
    out, err, status = Open3.capture3(cli, *args, chdir: chdir)
    raise "Native command #{args.inspect} failed: #{err}" unless status.success?

    out
  end

  def self.add(cli, dir, descriptor, ordinal)
    args = %w[local add]
    descriptor.fetch('tags').each { |tag| args.push('--tag', tag) }
    descriptor.fetch('formats').each do |format|
      payload = "native fixture #{ordinal} #{descriptor.fetch('tuple').join('/')} #{format}\n"
      path = File.join(dir, "input-#{format}")
      File.binwrite(path, payload)
      args.push(format == 'tar' ? '--archive' : '--stream', path)
    end
    run(cli, *args, *descriptor.fetch('tuple'), chdir: dir)
  end

  def self.snapshot(dir)
    index = File.binread(File.join(dir, 'v1/INDEX.json'))
    files = {}
    aliases = {}
    Dir.glob(File.join(dir, 'v1/**/*')).each do |path|
      rel = path.delete_prefix("#{dir}/")
      if File.symlink?(path)
        aliases[rel] = File.readlink(path)
      elsif File.file?(path) && !path.end_with?('/INDEX.json')
        files[rel] = { 'sha256' => Digest::SHA256.file(path).hexdigest,
                       'size' => File.size(path), 'contents' => File.binread(path) }
      end
    end
    { 'index' => JSON.parse(index), 'index_bytes' => index,
      'files' => files, 'aliases' => aliases }
  end

  def self.generate(name, cli, check: false)
    spec = scenarios.fetch(name)
    Dir.mktmpdir('osctl-repo-native-') do |dir|
      run(cli, 'local', 'init', chdir: dir)
      spec.fetch('baseline').each_with_index { |d, i| add(cli, dir, d, i) }
      run(cli, 'local', 'default', 'vpsadminos', chdir: dir)
      run(cli, 'local', 'default', 'vpsadminos', 'minimal', chdir: dir)
      baseline = snapshot(dir)
      spec.fetch('updates').each_with_index { |d, i| add(cli, dir, d, 100 + i) }
      before_gc = snapshot(dir)
      config = File.join(dir, 'gc.json')
      File.write(config, JSON.generate('gc' => spec.fetch('gc')))
      # This is the same placeholder substitution used by the Nix module.
      gc = File.read(File.join(ROOT, GC_SOURCE)).sub('@osctlRepo@/bin/osctl-repo', cli)
      program = File.join(dir, 'gc.rb')
      File.write(program, gc)
      gc_log = run(RbConfig.ruby, program, config, chdir: dir)
      result = {
        'description' => name, 'operations' => spec,
        'baseline' => baseline, 'before_gc' => before_gc,
        'after_gc' => snapshot(dir), 'gc_stdout' => gc_log,
        'provenance' => {
          'revision' => run('git', 'rev-parse', 'HEAD', chdir: ROOT).strip,
          'sources' => SOURCE_FILES.to_h { |p| [p, Digest::SHA256.file(File.join(ROOT, p)).hexdigest] }
        }
      }
      path = File.join(FIXTURES, "#{name}.json")
      if check
        expected = JSON.parse(File.read(path))
        # Source hashes bind the oracle. Unrelated commits do not change it.
        expected.fetch('provenance').delete('revision')
        result.fetch('provenance').delete('revision')
        raise "Native oracle drift in #{name}" unless result == expected
      else
        FileUtils.mkdir_p(FIXTURES)
        File.write(path, "#{JSON.generate(result)}\n")
      end
      puts "#{check ? 'Checked' : 'Generated'} #{name}: #{result.fetch('after_gc').fetch('index').fetch('images').length} retained images"
    end
  end
end

if $0 == __FILE__
  name, cli, mode = ARGV
  abort "Usage: ruby #{$0} catalog|gc|subset|mixed_failure /absolute/osctl-repo" unless name && cli
  abort 'Native CLI must be an absolute path without whitespace' unless cli.start_with?('/') && !cli.match?(/\s/)

  NativeOracle.generate(name, cli, check: mode == '--check')
end
