require 'digest'
require 'forwardable'
require 'libosctl'
require 'singleton'
require 'osctld/cgroup'

module OsCtld
  # Manage a list of BPF programs and their links
  #
  # Program name is a hash of the listed devices, so identical programs are loaded
  # just once and reused. Program links (i.e. attach on a cgroup) are tracked
  # and when a program has no links left, it is destroyed.
  class Devices::V2::BpfProgramCache
    include Singleton
    include OsCtl::Lib::Utils::Log

    class << self
      extend Forwardable
      def_delegators :instance, :assets, :set, :get_prog_name, :load_links,
                     :prune_cgroup_links
    end

    def initialize
      @mutex = Mutex.new
      @programs = {}
      @links = {}
      @path_cache = {}

      load_programs
    end

    # @param add [Assets::Definition]
    def assets(add)
      sync do
        @programs.each_value do |prog|
          add.file(
            prog.path,
            desc: "BPF program #{prog.name}",
            user: 0,
            group: 0,
            mode: 0o600
          )
        end

        @links.each_value do |cgroup_paths|
          cgroup_paths.each_value do |link|
            add.file(
              link.path,
              desc: "BPF program #{link.prog_name} attached on #{link.cgroup_path}",
              user: 0,
              group: 0,
              mode: 0o600
            )
          end
        end
      end
    end

    # Detect existing links in BPF FS
    # @param pool_name [String]
    def load_links(pool_name)
      sync do
        cnt = 0

        BpfFs.list_links(pool_name).each do |link_name|
          link = Devices::V2::BpfLink.from_name(pool_name, link_name)

          key = cgroup_key(link.cgroup_path)
          @links[link.prog_name] ||= {}
          @links[link.prog_name][key] = link

          @path_cache[key] = link

          cnt += 1
        end

        log(:info, "Loaded #{cnt} links")
      end
    end

    # Attach program allowing access to the specified devices to a cgroup
    #
    # The program is attached only if it is not already attached. If `prog_name`
    # is given, it is a caller hint; the pinned cached link identifies the
    # actual program to replace, including inherited public-root aliases.
    #
    # @param pool_name [String]
    # @param devices [Array<Devices::Device>]
    # @param cgroup_path [String]
    # @param prog_name [String, nil] previous program name
    # @return [String] program name
    def set(pool_name, devices, cgroup_path, prog_name: nil)
      sync do
        BpfFs.setup
        BpfFs.add_pool(pool_name)

        new_prog_name = get_prog_name(devices)

        prog = @programs[new_prog_name]

        unless prog&.exist?
          prog = @programs[new_prog_name] = Devices::V2::BpfProgram.new(
            new_prog_name,
            devices
          )
          prog.create
        end

        key = cgroup_key(cgroup_path)
        old_link = @path_cache[key]
        old_link = nil if old_link && !BpfFs.link_pinned?(old_link.pool_name, old_link.name)

        # An adopted public-root pin remains valid after the hierarchy becomes
        # private. Its basename must not be rewritten before link replacement.
        return new_prog_name if old_link && old_link.prog_name == new_prog_name

        link = Devices::V2::BpfLink.new(new_prog_name, pool_name, cgroup_path)

        unless prog.attached?(link)
          if old_link
            prog.replace(old_link, link)
          else
            prog.attach(link)
          end
        end

        # Commit bookkeeping only after the kernel operation succeeded. A
        # failed replacement must retain the old pin for retry and cleanup.
        @links[old_link.prog_name].delete(key) if old_link
        @links[new_prog_name] ||= {}
        @links[new_prog_name][key] = link
        @path_cache[key] = link

        if old_link && @links[old_link.prog_name].empty?
          old_prog = @programs.delete(old_link.prog_name)
          @links.delete(old_link.prog_name)
          old_prog.destroy
        end

        new_prog_name
      end
    end

    # @param devices [Array<Devices::Device>]
    # @return [String]
    def get_prog_name(devices)
      data = devices.map(&:to_s).join(';')
      Digest::SHA2.hexdigest(data)[0..10]
    end

    # Remove program links to the specified cgroup
    # @param cgroup_path [String]
    def prune_cgroup_links(cgroup_path)
      sync do
        key = cgroup_key(cgroup_path)
        link = @path_cache[key]
        return if link.nil?

        prog = @programs[link.prog_name]
        prog.detach(link)
        @path_cache.delete(key)
        @links[link.prog_name].delete(key)

        if @links[link.prog_name].empty?
          @links.delete(link.prog_name)
          @programs.delete(link.prog_name)
          prog.destroy
        end
      end

      nil
    end

    def log_type
      'bpf-program-cache'
    end

    protected

    # CGroup setup validates the public/private views of the same hierarchy.
    # Cache by their common logical path, while BpfLink preserves the actual
    # existing pin name. Do not treat a similarly prefixed path as an alias.
    def cgroup_key(path)
      root = CGroup::DEFAULT_FS
      return CGroup::RUNSTATE_FS if path == root
      return path unless path.start_with?("#{root}/")

      "#{CGroup::RUNSTATE_FS}#{path.delete_prefix(root)}"
    end

    def load_programs
      sync do
        BpfFs.list_progs.each do |prog_name|
          @programs[prog_name] = Devices::V2::BpfProgram.new(prog_name, nil)
        end

        log(:info, "Loaded #{@programs.length} programs")
      end
    end

    def sync(&block)
      if @mutex.owned?
        block.call
      else
        @mutex.synchronize(&block)
      end
    end
  end
end
