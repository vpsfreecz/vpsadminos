require 'json'
require 'open3'
require 'shellwords'
require 'tmpdir'
require 'fileutils'
require 'digest'

module OsCtl::Image
  # Dispatch-time identity. A private scripts copy prevents shell build/test code
  # from sourcing date-dependent config again after midnight.
  class AssignedConfig
    KEYS = %w[BUILDER DISTNAME RELVER ARCH VENDOR VARIANT DATASETS SPIN SPINVER].freeze
    TUPLE = { 'vendor' => 'VENDOR', 'variant' => 'VARIANT', 'arch' => 'ARCH',
              'distribution' => 'DISTNAME', 'version' => 'RELVER' }.freeze

    attr_reader :data

    def self.capture(base_dir, name, source:)
      output, status = Open3.capture2e(File.join(base_dir, 'bin/config'), 'image', 'capture', name)
      raise OperationError, "config capture failed: #{output}" unless status.success?

      config = output.lines.to_h do |line|
        key, value = Shellwords.split(line.chomp).fetch(0).split('=', 2)
        [key, value]
      end
      config['VENDOR'] = 'vpsadminos' if config['VENDOR'].to_s.empty?
      config['VARIANT'] = 'minimal' if config['VARIANT'].to_s.empty?
      data = { 'schema' => 1, 'name' => name, 'source' => source, 'config' => config }
      data['config_digest'] = digest(data)
      new(data)
    end

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def self.digest(data)
      Digest::SHA256.hexdigest(JSON.generate(data.except('config_digest').sort.to_h))
    end

    def initialize(data)
      @data = data
      raise ArgumentError, 'assigned config digest mismatch' unless data['config_digest'] == self.class.digest(data)
      raise ArgumentError, 'unsupported assigned config schema' unless data['schema'] == 1
      raise ArgumentError, 'source must be an exact Git revision' unless data['source'].to_s.match?(/\A[0-9a-f]{40}\z/)
      raise ArgumentError, 'invalid image name' unless data['name'].to_s.match?(/\A[\w.-]+(?:#variant=[\w.-]+)?\z/)
      raise ArgumentError, 'unknown config fields' unless (data.fetch('config').keys - KEYS).empty?

      %w[BUILDER DISTNAME RELVER ARCH VENDOR VARIANT].each do |key|
        raise ArgumentError, "invalid captured #{key}" unless data['config'][key].to_s.match?(/\A[\w.+-]+\z/)
      end
    end

    def tuple
      TUPLE.transform_values { |key| data.fetch('config').fetch(key) }
    end

    def formats
      data.fetch('config').fetch('DATASETS', '').empty? ? %w[tar zfs] : ['zfs']
    end

    def save(path)
      File.write(path, "#{JSON.pretty_generate(data)}\n")
    end

    def with_scripts(base_dir)
      Dir.mktmpdir('osctl-image-assigned.') do |dir|
        FileUtils.cp_r(File.join(base_dir, '.'), dir, preserve: true)
        # Builders bind this private copy without ID mapping. Their mapped
        # root must be able to read/traverse it, including mktmpdir's 0700 root.
        # FileUtils' X covers directories only, so copy executable owner bits.
        FileUtils.chmod_R('u+rwX,go=u,go-w', dir)
        config = File.join(dir, 'images', data.fetch('name').split('#').first, 'config.sh')
        real = File.realpath(config)
        raise ArgumentError, 'image config escapes scripts' unless real.start_with?("#{dir}/")

        File.write(real, data.fetch('config').map { |k, v| "#{k}=#{Shellwords.escape(v)}\n" }.join)
        yield dir
      end
    end
  end
end
