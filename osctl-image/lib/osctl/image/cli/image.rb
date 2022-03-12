require 'json'
require 'libosctl'
require 'osctl/image/cli/command'

module OsCtl::Image
  class Cli::Image < Cli::Command
    FIELDS = %i(name distribution version arch vendor variant)

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      tpls = image_list.map do |tpl|
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
      require_args!('image')

      results, _ = build_images(select_images(args[0]))
      process_build_results(results)
    end

    def test
      require_args!('image', strict: false)

      images = select_images(args[0])
      tests = select_tests(args[1])
      results = test_images(images, tests)
      process_test_results(results)
    end

    def instantiate
      require_args!('image')

      image = image_list.detect { |t| t.name == args[0] }
      fail "image '#{args[0]}' not found" unless image

      ctid = Operations::Image::Instantiate.run(
        File.absolute_path('.'),
        image,
        output_dir: opts['output-dir'],
        build_dataset: opts['build-dataset'],
        vendor: opts[:vendor],
        rebuild: opts[:rebuild],
        ctid: opts[:container],
      )

      puts "Container ID: #{ctid}"
    end

    def deploy
      require_args!('image', 'repository')

      unchanged = false

      # Build images
      images = select_images(args[0])
      build_results, cached_builds = build_images(
        select_images(args[0]),
        rebuild: opts[:rebuild],
      )
      process_build_results(build_results)

      successful_builds =
        build_results.select(&:status).map(&:return_value) \
        + \
        cached_builds

      fail 'no images to test and deploy' if successful_builds.empty?

      if opts['skip-tests']
        puts 'Skipping tests'
        verified_builds = successful_builds
      else
        # Test successfully built images
        tests = TestList.new('.')
        test_results = []

        puts 'Testing images'

        verified_builds = successful_builds.select do |build|
          if image_in_repo_unchanged?(build, args[1])
            unchanged = true
            next false
          end

          results = test_images([build.image], tests, rebuild: false)
          test_results.concat(results)
          results.all?(&:success?)
        end

        process_test_results(test_results)
      end

      if verified_builds.empty?
        if unchanged
          puts 'no images to deploy'
        else
          fail 'no images to deploy'
        end

        return
      end

      # Deploy verified images
      puts 'Deploying images'

      verified_builds.each do |build|
        Operations::Image::Deploy.run(build, args[1], tags: opts[:tag])
      end
    end

    protected
    def build_images(images, rebuild: true)
      cached = []
      op = Operations::Execution::Parallel.new(opts[:jobs])

      images.each do |tpl|
        build = Operations::Image::Build.new(
          File.absolute_path('.'),
          tpl,
          output_dir: opts['output-dir'],
          build_dataset: opts['build-dataset'],
          vendor: opts[:vendor],
        )

        if rebuild || !build.cached?
          op.add(tpl) { build.execute }
        else
          cached << build
        end
      end

      puts 'Building images...'
      results = op.execute
      [results, cached]
    end

    def process_build_results(results)
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

    def test_images(images, tests, rebuild: nil)
      rebuild = opts[:rebuild] if rebuild.nil?
      results = []

      images.each do |tpl|
        results.concat(
          Operations::Test::Image.run(
            File.absolute_path('.'),
            tpl,
            tests,
            output_dir: opts['output-dir'],
            build_dataset: opts['build-dataset'],
            vendor: opts[:vendor],
            rebuild: rebuild,
            keep_failed: opts['keep-failed'],
          )
        )
      end

      results
    end

    def process_test_results(results)
      succeded = results.select { |t| t.success? }
      failed = results.reject { |t| t.success? }

      puts "#{results.length} tests run, #{succeded.length} succeeded, "+
           "#{failed.length} failed"
      return if failed.length == 0

      puts
      puts "Failed tests:"

      failed.each_with_index do |st, i|
        puts "#{i+1}) Test #{st.test} on #{st.image}:"
        puts "  Exit status: #{st.exitstatus}"
        puts "  Output:"
        st.output.split("\n").each { |line| puts (' '*4)+line }
        puts
      end
    end

    # @param build [Operations::Image::Build]
    # @param repo [String] path to the repository
    def image_in_repo_unchanged?(build, repo)
      img = build.image
      path = Operations::Repository::GetImagePath.run(
        repo,
        {
          distribution: img.distribution,
          version: img.version,
          arch: img.arch,
          variant: img.variant,
          vendor: img.vendor,
        },
        :zfs,
      )

      Operations::File::Compare.run(path, build.output_stream)

    rescue OperationError
      false
    end

    # @param arg [String]
    # @return [Array<Image>]
    def select_images(arg)
      existing_images = image_list

      if arg == 'all'
        existing_images
      else
        arg.split(',').map do |v|
          tpl = existing_images.detect { |t| t.name == v }
          raise GLI::BadCommandLine, "image '#{v}' not found" if tpl.nil?
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

    def image_list
      ImageList.new('.')
    end
  end
end
