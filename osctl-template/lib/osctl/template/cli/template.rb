require 'json'
require 'libosctl'
require 'osctl/template/cli/command'

module OsCtl::Template
  class Cli::Template < Cli::Command
    FIELDS = %i(name distribution version arch vendor variant)

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      tpls = template_list.map do |tpl|
        tpl.load_config

        {
          name: tpl.name,
          distribution: tpl.distribution,
          version: tpl.version,
          arch: tpl.arch,
          vendor: tpl.vendor,
          variant: tpl.variant,
        }
      end

      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
        header: !opts['hide-header'],
      }

      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : FIELDS

      OsCtl::Lib::Cli::OutputFormatter.print(tpls, cols, fmt_opts)
    end

    def build
      require_args!('template')

      op = Operations::Execution::Parallel.new(opts[:jobs])

      select_templates(args[0]).each do |tpl|
        op.add(tpl) do
          Operations::Template::Build.run(
            File.absolute_path('.'),
            tpl,
            output_dir: opts['output-dir'],
            build_dataset: opts['build-dataset'],
            vendor: opts[:vendor],
          )
        end
      end

      puts "Building templates..."
      results = op.execute

      puts "Build results:"
      results.each do |res|
        tpl = res.obj
        build = res.return_value

        if res.status
          puts "#{tpl.name}: #{build.output_tar}"
          puts "#{tpl.name}: #{build.output_stream}"
        else
          puts "#{tpl.name}: failed with #{res.exception.class}: #{res.exception.message}"
        end
      end
    end

    def test
      require_args!('template')

      templates = select_templates(args[0])
      tests = select_tests(args[1])
      results = []

      templates.each do |tpl|
        results.concat(
          Operations::Test::Template.run(
            File.absolute_path('.'),
            tpl,
            tests,
            output_dir: opts['output-dir'],
            build_dataset: opts['build-dataset'],
            vendor: opts[:vendor],
            rebuild: opts[:rebuild],
          )
        )
      end

      succeded = results.select { |t| t.success? }
      failed = results.reject { |t| t.success? }

      puts "#{results.length} tests run, #{succeded.length} succeeded, "+
           "#{failed.length} failed"
      return if failed.length == 0

      puts
      puts "Failed tests:"

      failed.each_with_index do |st, i|
        puts "#{i+1}) Test #{st.test} on #{st.template}:"
        puts "  Exit status: #{st.exitstatus}"
        puts "  Output:"
        st.output.split("\n").each { |line| puts (' '*4)+line }
        puts
      end
    end

    def instantiate
      require_args!('template')

      template = template_list.detect { |t| t.name == args[0] }
      fail "template '#{args[0]}' not found" unless template

      ctid = Operations::Template::Instantiate.run(
        File.absolute_path('.'),
        template,
        output_dir: opts['output-dir'],
        build_dataset: opts['build-dataset'],
        vendor: opts[:vendor],
        rebuild: opts[:rebuild],
        ctid: opts[:container],
      )

      puts "Container ID: #{ctid}"
    end

    protected
    # @param arg [String]
    # @return [Array<Template>]
    def select_templates(arg)
      existing_templates = template_list

      if arg == 'all'
        existing_templates
      else
        arg.split(',').map do |v|
          tpl = existing_templates.detect { |t| t.name == v }
          raise GLI::BadCommandLine, "template '#{v}' not found" if tpl.nil?
          tpl
        end
      end
    end

    # @param arg [String, nil]
    # @return [Array<Test>]
    def select_tests(arg)
      existing_tests = TestList.new('.')

      if arg.nil? || arg == 'all'
        existing_tests
      else
        arg.split(',').map do |v|
          test = existing_tests.detect { |t| t.name == v }
          raise GLI::BadCommandLine, "test '#{v}' not found" if test.nil?
          test
        end
      end
    end

    def template_list
      TemplateList.new('.')
    end
  end
end
