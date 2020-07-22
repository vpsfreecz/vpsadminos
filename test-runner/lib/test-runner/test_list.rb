require 'json'

module TestRunner
  class TestList
    # Return a list of all known tests
    # @return [Array<Test>]
    def all
      parse_many(extract)
    end

    # Filter through all tests, return those that the filter matched
    # @yieldparam [Test]
    # @return [Array<Test>]
    def filter(&block)
      all.select(&block)
    end

    # Return one test specified by path
    # @return [Test]
    def by_path(path)
      parse_one(path, extract(path: path))
    end

    protected
    def extract(path: nil)
      cmd = [
        'nix-instantiate',
        '--eval',
        '--json',
        '--strict',
        '--read-write-mode',
      ]

      cmd << '--attr' << path if path
      cmd << 'tests/list-tests.nix'

      json = `#{cmd.join(' ')}`

      if $?.exitstatus != 0
        fail "nix-instantiate failed with exit status #{$?.exitstatus}"
      end

      json
    end

    def parse_many(json)
      JSON.parse(json, symbolize_names: true).map do |name, opts|
        create_test(name, opts)
      end
    end

    def parse_one(path, json)
      create_test(path, JSON.parse(json, symbolize_names: true))
    end

    def create_test(path, data)
      Test.new(
        path: path.to_s,
        name: data[:name],
        description: data[:description],
      )
    end
  end
end
