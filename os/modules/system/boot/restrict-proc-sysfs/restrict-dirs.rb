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
    File.chmod(st.mode & 0o770, path)
  end

  def do_skip(path); end

  def do_grant(path)
    st = File.stat(path)

    if st.directory?
      File.chmod(0o777, path)
    else
      File.chmod(0o666, path)
    end
  end
end

class RestrictDirs
  KERNFS_FILTER_REPLACE = '/proc/vpsadminos/kernfs_filter/replace'.freeze

  def initialize(config_path)
    @cmds = parse(config_path)
  end

  def run
    operations = resolve_operations

    if kernfs_filter_available?
      policy = build_kernfs_filter_policy(operations)

      if policy && install_kernfs_filter_policy(policy)
        apply_grants(operations)
        return
      end

      warn 'kernfs_filter cannot express the full configuration, falling back to chmod restrictions'
    end

    run_chmod_restrictions(operations)
  end

  protected

  attr_reader :cmds

  def resolve_operations
    resolved = {}

    cmds.each do |c|
      Dir.glob(c.path_arg).each do |f|
        resolved[f] = c
      end
    end

    resolved
  end

  def run_chmod_restrictions(operations)
    operations.sort { |a, b| a[0] <=> b[0] }.each do |path, op|
      op.execute(path)
    end
  end

  def apply_grants(operations)
    operations.sort { |a, b| a[0] <=> b[0] }.each do |path, cmd|
      cmd.execute(path) if cmd.name == 'grant'
    end
  end

  def kernfs_filter_available?
    File.writable?(KERNFS_FILTER_REPLACE)
  end

  def build_kernfs_filter_policy(operations)
    lines = [
      'version 1',
      'scope noninit-userns'
    ]

    operations.sort { |a, b| a[0] <=> b[0] }.each do |path, cmd|
      rule = command_to_kernfs_filter_rule(cmd, path)
      return nil unless rule

      lines << rule
    end

    "#{lines.join("\n")}\n"
  end

  def command_to_kernfs_filter_rule(cmd, resolved_path = cmd.path_arg)
    fs, path = split_kernfs_filter_path(resolved_path)
    return nil unless fs

    action =
      case cmd.name
      when 'restrict'
        'hide'
      when 'skip', 'grant'
        'allow'
      else
        return nil
      end

    "#{fs} #{action} any #{recursive_kernfs_filter_path(path)}"
  end

  def split_kernfs_filter_path(path)
    if path == '/proc'
      ['proc', '/']
    elsif path.start_with?('/proc/')
      ['proc', path.delete_prefix('/proc')]
    elsif path == '/sys'
      ['sysfs', '/']
    elsif path.start_with?('/sys/')
      ['sysfs', path.delete_prefix('/sys')]
    end
  end

  def recursive_kernfs_filter_path(path)
    normalized = path.chomp('/')
    normalized = '/' if normalized.empty?

    return '/**' if normalized == '/'
    return normalized if normalized.end_with?('/**')

    "#{normalized}/**"
  end

  def install_kernfs_filter_policy(policy)
    File.write(KERNFS_FILTER_REPLACE, policy)
    puts "installed kernfs_filter policy with #{policy.lines.count - 2} rules"
    true
  rescue SystemCallError, IOError => e
    warn "failed to install kernfs_filter policy: #{e.message}"
    false
  end

  def parse(config_path)
    ret = []

    File.open(config_path) do |f|
      f.each_line do |line|
        next if line.start_with?('#') || line.strip.empty?

        cmd, *args = line.strip.split
        ret << Command.new(cmd, args)
      end
    end

    ret
  end
end

if $0 == __FILE__
  Dir.chdir('/')
  rd = RestrictDirs.new(ARGV[0])
  rd.run
end
