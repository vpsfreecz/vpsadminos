module VpsAdminOS::Converter
  # Store/load migration state to/from disk
  class Cli::Vz6::State < Cli::Command
    DIR = '~/.vpsadminos-converter'
    STEPS = %i(stage sync cancel transfer cleanup)

    # Create a new migration state, save it to disk and return it
    # @param vz_ct [Vz6::Container]
    # @param target_ct [Container]
    # @param m_opts [Hash] migration options
    # @param cli_opts [Hash] CLI options
    # @return [Cli::Vz6::State]
    def self.create(vz_ct, target_ct, m_opts, cli_opts)
      s = new(target_ct.id, {
        step: :stage,
        vz_ct: vz_ct,
        target_ct: target_ct,
        m_opts: m_opts,
        cli_opts: cli_opts,
        snapshots: [],
      })
      s.save
      s
    end

    # Load migration state from disk
    # @param ctid [String]
    # @return [Cli::Vz6::State]
    def self.load(ctid)
      ret = File.open(state_file(ctid)) do |f|
         Marshal.load(f)
      end

      fail 'invalid state format' unless ret.is_a?(Hash)
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

    # Migration options (passed to {OsCtl::Lib::Utils::Migration#migrate_ssh_cmd)
    # @return [Hash]
    attr_reader :m_opts

    # Command-line options
    # @return [Hash]
    attr_reader :cli_opts

    # List of created snapshots
    # @return [Array<String>]
    attr_reader :snapshots

    def initialize(ctid, data)
      @ctid = ctid

      data.each do |k, v|
        instance_variable_set("@#{k}", v)
      end
    end

    # @param step [Symbol]
    def can_proceed?(new_step)
      return false if new_step == step

      new_i = STEPS.index(new_step)
      cur_i = STEPS.index(step)

      return false if new_i < cur_i
      return true if new_step == :transfer && step == :sync
      return false if new_step != :cancel && new_i != (cur_i + 1)
      true
    end

    # @param step [Symbol]
    def set_step(new_step)
      fail 'invalid migration sequence' unless can_proceed?(new_step)
      @step = new_step
    end

    # Persist the state to disk
    def save
      Dir.mkdir(state_dir, 0700) unless Dir.exist?(state_dir)

      orig = state_file
      tmp = "#{orig}.new"

      File.open(tmp, 'w', 0700) do |f|
        Marshal.dump({
          step: step,
          vz_ct: vz_ct,
          target_ct: target_ct,
          m_opts: m_opts,
          cli_opts: cli_opts,
          snapshots: snapshots,
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
