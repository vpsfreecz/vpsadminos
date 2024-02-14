require 'filelock'
require 'libosctl'

module SvCtl
  # Manage a file-based list of strings
  class ItemFile
    include OsCtl::Lib::Utils::File

    # @return [String]
    attr_reader :path

    # @param path [String] path to a file where the list is stored
    # @yieldparam [ItemFile]
    def initialize(path, **, &block)
      @path = path
      @lock_path = File.join(File.dirname(path), ".#{File.basename(path)}.lock")
      @opened = false

      # rubocop:disable Security/Open
      # rubocop thinks this is Kernel#open
      open(**, &block) if block
      # rubocop:enable Security/Open
    end

    # @yieldparam [ItemFile]
    def open
      sync do
        @items = []
        parse
        yield(self)
        save
      end

      nil
    end

    def open?
      @opened
    end

    # Return the list
    # @return [Array<String>]
    def get
      must_be_open!
      items
    end

    def each(&)
      must_be_open!
      items.each(&)
    end

    # Is item in the list?
    # @param item [String]
    def include?(item)
      must_be_open!
      items.include?(item)
    end

    # Add item to the list
    # @param item [String]
    def <<(item)
      must_be_open!
      items << item unless items.include?(item)
    end

    # Remove item from the list
    # @param item [String]
    def delete(item)
      must_be_open!
      items.delete(item)
    end

    # Save the list
    def save
      must_be_open!

      if items.empty?
        unlink_if_exists(path)
        return
      end

      regenerate_file(path, 0o644) do |new|
        items.each { |item| new.puts(item) }
      end
    end

    protected

    attr_reader :lock_path, :items

    def must_be_open!
      raise 'file list not open' unless open?
    end

    def sync
      Filelock(lock_path) do
        @opened = true

        begin
          yield
        ensure
          @opened = false
        end
      end
    end

    def parse
      File.open(path) do |f|
        f.each_line do |line|
          stripped = line.strip
          next if stripped.empty?

          items << stripped
        end
      end
    rescue Errno::ENOENT
      # ignore
    end
  end
end
