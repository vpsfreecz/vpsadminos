#!@ruby@/bin/ruby

class Command
  attr_reader :name, :path_arg

  def initialize(name, args)
    @name = name
    @path_arg = args[0]
  end

  def execute(path)
    puts "#{name.ljust(10)} #{path}"
    send(:"do_#{name}", path)
  end

  protected
  def do_restrict(path)
    st = File.stat(path)
    File.chmod(st.mode & 0770, path)
  end

  def do_skip(path)
  end

  def do_grant(path)
    st = File.stat(path)

    if st.directory?
      File.chmod(0777, path)
    else
      File.chmod(0666, path)
    end
  end
end

class RestrictDirs
  def initialize(config_path)
    @cmds = parse(config_path)
    @ops = {}
  end

  def run
    cmds.each do |c|
      Dir.glob(c.path_arg).each do |f|
        ops[f] = c
      end
    end

    ops.sort { |a, b| a[0] <=> b[0] }.each do |path, op|
      op.execute(path)
    end
  end

  protected
  attr_reader :cmds, :ops

  def parse(config_path)
    ret = []

    File.open(config_path) do |f|
      f.each_line do |line|
        next if line.start_with?('#')

        cmd, *args = line.strip.split
        ret << Command.new(cmd, args)
      end
    end

    ret
  end
end

Dir.chdir('/')
rd = RestrictDirs.new(ARGV[0])
rd.run
