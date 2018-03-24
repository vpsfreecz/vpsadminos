module OsCtl::Cli
  class Tree
    DECORATIONS = {
      ascii: {
        branch: '|-- ',
        leaf: '`-- ',
        continuation: '|   '
      },
      unicode: {
        branch: '├── ',
        leaf: '└── ',
        continuation: '│   '
      },
    }

    include OsCtl::Utils::Humanize
    include CGroupParams

    def self.print(*args)
      tree = new(*args)
      tree.render
      tree.print
    end

    def initialize(pool, parsable: false, containers: false)
      @pool = pool
      @parsable = parsable
      @containers = containers
    end

    def render
      fetch
      preprocess

      decor = decorations
      i = 0

      groups.map! do |grp|
        # Look ahead to see if the group has any more siblings on the same level
        has_sibling = groups[i+1..-1].detect { |g| g[:parent] == grp[:parent] }

        if has_sibling
          dir_indent = decor[:branch]
        else
          dir_indent = decor[:leaf]
        end

        res = ''

        # For every level, we need to find out whether the groups have any siblings
        # on that level
        t = ''
        res << grp[:parts][0..-3].inject('') do |acc, v|
          t = File.join(t, v)

          has_sibling = groups[i+1..-1].detect { |g| g[:parent] == t }

          if has_sibling
            acc << decor[:continuation]
          else
            acc << '    '
          end
        end

        res << dir_indent if grp[:parent]
        res << grp[:shortname]

        grp[:branch] = res

        i += 1
        grp
      end
    end

    def print
      OutputFormatter.print(
        groups,
        [{label: 'GROUP', name: :branch}, :memory, :cpu_time],
        layout: :columns
      )
    end

    protected
    attr_reader :pool, :parsable, :client, :groups, :cts

    def fetch
      @client = OsCtl::Client.new
      @client.open

      @groups = @client.cmd_data!(:group_list, pool: pool).sort! do |a, b|
        a[:name] <=> b[:name]
      end

      @cts = @client.cmd_data!(:ct_list, pool: pool) if @containers
    end

    def preprocess
      groups.map! do |grp|
        cg_add_stats(
          client,
          grp,
          grp[:full_path],
          %i(memory cpu_time),
          parsable
        )

        if grp[:name] == '/'
          grp[:parts] = ['/']
          grp[:shortname] = '/'
          grp[:parent] = nil

        else
          parts = grp[:name].split('/')
          grp[:parts] = parts
          grp[:shortname] = parts.last
          grp[:parent] = parts[0..-2].join('/')
          grp[:parent] = '/' if grp[:parent].empty?
        end

        next grp unless cts

        group_cts = cts.select { |ct| ct[:group] == grp[:name] }.sort! do |a, b|
          a[:id] <=> b[:id]
        end.map! do |ct|
          cg_add_stats(
            client,
            ct,
            ct[:group_path],
            %i(memory cpu_time),
            parsable
          )

          ct[:parts] = ct[:group].split('/') << ct[:id]
          ct[:shortname] = ct[:id]
          ct[:parent] = ct[:group]
          ct
        end

        [grp, group_cts]
      end.flatten!
    end

    def decorations
      if ENV['LANG']
        DECORATIONS[ /UTF-8/i =~ ENV['LANG'] ? :unicode : :ascii ]

      else
        DECORATIONS[:ascii]
      end
    end
  end
end
