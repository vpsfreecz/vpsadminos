require 'erb'

module OsCtl::Lib
  class Cli::Completion::Bash
    class OptArg
      attr_reader :cmd, :name, :expand

      # @param opts [Hash]
      # @option opts [:all, Array<Symbol>] :cmd
      # @option opts [Symbol] :name
      # @option opts [String] :expand
      def initialize(opts)
        if opts[:cmd].is_a?(Symbol)
          @cmd = opts[:cmd]
        else
          @cmd = opts[:cmd].map(&:to_s)
        end

        @name = opts[:name].to_s
        @expand = opts[:expand]
      end

      # @param cmd_path [Array<String>]
      # @param arg [String]
      def applicable?(cmd_path, arg)
        return false if name != arg
        return true if cmd == :all

        cmd.zip(cmd_path).each do |x, y|
          return false if y.nil? || x != y
        end

        true
      end
    end

    # @return [Array<String>] shortcuts to subcommands
    attr_accessor :shortcuts

    # @return [String]
    attr_reader :app_prefix

    # @param app [GLI::App]
    def initialize(app)
      @app = app
      @opts = []
      @args = []
      @shortcuts = []
      @app_prefix = "_#{app.exe_name.gsub('-', '_')}"
    end

    # @param opts [Hash]
    # @option opts [Symbol, Array<Symbol>] :cmd
    # @option opts [Symbol] :name
    # @option opts [String] :expand
    def opt(opts)
      @opts << OptArg.new(opts)
    end

    # @param opts [Hash]
    # @option opts [Symbol, Array<Symbol>] :cmd
    # @option opts [Symbol] :name
    # @option opts [String] :expand
    def arg(opts)
      @args << OptArg.new(opts)
    end

    def generate
      ERB.new(
        File.new(File.join(
          __dir__, '../../../..', 'templates/completion/bash.erb'
        )).read,
        trim_mode: '-',
      ).result(binding)
    end

    protected
    attr_reader :app, :opts, :args

    def commands(cmd = nil)
      (cmd || app).commands.reject do |name, cmd|
        cmd.description.nil? || name.to_s.start_with?('_')
      end
    end

    def global_commands
      ret = []

      app.commands.each_value do |c|
        ret << c.name
        ret.concat(c.aliases) if c.aliases
      end

      ret
    end

    def each_command(parent: nil, path: [], &block)
      if parent.nil?
        yield(app, [app.exe_name])
        each_command(parent: app, path: [app.exe_name], &block)

      else
        parent.commands.each_value do |c|
          ([c.name] + (c.aliases || [])).each do |name|
            name_s = name.to_s
            block.call(c, path + [name_s])
            each_command(parent: c, path: path + [name_s], &block)
          end
        end
      end
    end

    def opt_word_list(cmd, path, name, opt, arg_name)
      optarg = opts.detect { |v| v.applicable?(path, arg_name) }

      if optarg
        optarg.expand

      elsif cmd.flags[name].must_match
        "echo #{cmd.flags[name].must_match.join(' ')}"
      else
        ''
      end
    end

    def arg_word_list(cmd, path, arg)
      optarg = args.detect { |v| v.applicable?(path, arg) }
      optarg ? optarg.expand : ''
    end

    def options(cmd = nil)
      ret = []

      # Boolean switches
      (cmd || app).switches.each_value do |sw|
        sw.arguments_for_option_parser.each do |arg|
          if arg.include?('[no-]')
            ret << arg.sub('[no-]', '')
            ret << arg.sub('[no-]', 'no-')
          else
            ret << arg
          end
        end
      end

      # Flags with arguments
      (cmd || app).flags.each_value do |fl|
        fl.all_forms(', ').split(', ').each do |form|
          opt, _ = form.split('=')
          ret << opt
        end
      end

      ret
    end

    def flags(cmd = nil)
      ret = []

      # Flags with arguments
      (cmd || app).flags.each_value do |fl|
        fl.all_forms(', ').split(', ').each do |form|
          opt, _ = form.split('=')
          ret << opt
        end
      end

      ret
    end

    def each_flag(cmd = nil)
      # Flags with arguments
      (cmd || app).flags.each do |name, fl|
        fl.all_forms(', ').split(', ').each do |form|
          opt, arg = form.split('=')
          yield(name, fmt_opt(opt), arg)
        end
      end
    end

    def fmt_opt(v)
      v.gsub(/-/, '_')
    end

    def arguments(cmd)
      ret = []
      return ret unless cmd.respond_to?(:arguments_description)

      cmd.arguments_description.split(' ').each do |arg|
        if (arg.start_with?('<') && arg.end_with?('>')) \
           || (arg.start_with?('[') && arg.end_with?(']'))
          ret << arg[1..-2].gsub('|', '')
        end
      end

      ret
    end

    def app_exe
      app.exe_name
    end
  end
end
