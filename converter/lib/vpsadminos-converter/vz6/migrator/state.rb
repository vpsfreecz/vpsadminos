require 'vpsadminos-converter/vz6/migrator'

module VpsAdminOS::Converter
  # Store/load migration state to/from disk
  class Vz6::Migrator::State
    DIR = '~/.vpsadminos-converter'.freeze
    STEPS = %i[stage sync cancel transfer cleanup].freeze

    # Create a new migration state, save it to disk and return it
    # @param vz_ct [Vz6::Container]
    # @param target_ct [Container]
    # @param opts [Hash] migration options
    # @option opts [String] :dst
    # @option opts [Integer] :port
    # @option opts [Boolean] :zfs
    # @option opts [String] :zfs_dataset
    # @option opts [String] :zfs_subdir
    # @option opts [Boolean] :zfs_compressed_send
    # @return [Cli::Vz6::State]
    def self.create(vz_ct, target_ct, opts)
      new(target_ct.id, {
        step: :stage,
        vz_ct:,
        target_ct:,
        opts:,
        snapshots: []
      })
    end

    # Load migration state from disk
    # @param ctid [String]
    # @return [Cli::Vz6::State]
    def self.load(ctid)
      ret = File.open(state_file(ctid)) do |f|
        Marshal.load(f)
      end

      raise 'invalid state format' unless ret.is_a?(Hash)

      new(ctid, ret)
    end

    def self.state_dir
      @dir ||= File.expand_path(DIR)
    end

    def self.state_file(ctid)
      File.join(state_dir, "#{ctid}.state")
    end

    # @return [String]
    attr_reader :ctid

    # @return [Symbol]
    attr_reader :step

    # @return [Vz6::Container]
    attr_reader :vz_ct

    # @return [Container]
    attr_reader :target_ct

    # Migration options
    # @return [Hash]
    attr_reader :opts

    # List of created snapshots
    # @return [Array<String>]
    attr_reader :snapshots

    def initialize(ctid, data)
      @ctid = ctid

      data.each do |k, v|
        instance_variable_set("@#{k}", v)
      end
    end

    # @param new_step [Symbol]
    def can_proceed?(new_step)
      return false if new_step == step

      new_i = STEPS.index(new_step)
      cur_i = STEPS.index(step)

      return false if new_i < cur_i
      return true if new_step == :transfer && step == :sync
      return false if new_step != :cancel && new_i != (cur_i + 1)

      true
    end

    # @param new_step [Symbol]
    def set_step(new_step)
      raise 'invalid migration sequence' unless can_proceed?(new_step)

      @step = new_step
    end

    # Persist the state to disk
    def save
      FileUtils.mkdir_p(state_dir, mode: 0o700)

      orig = state_file
      tmp = "#{orig}.new"

      File.open(tmp, 'w', 0o700) do |f|
        Marshal.dump({
          step:,
          vz_ct:,
          target_ct:,
          opts:,
          snapshots:
        }, f)
      end

      File.rename(tmp, orig)
    end

    # Remove the state from disk
    def destroy
      File.unlink(state_file)
    end

    protected

    def state_dir
      self.class.state_dir
    end

    def state_file
      self.class.state_file(ctid)
    end
  end
end
