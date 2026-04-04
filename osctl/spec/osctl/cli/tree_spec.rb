# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Tree do
  def with_lang(lang)
    old = ENV.fetch('LANG', nil)
    ENV['LANG'] = lang
    yield
  ensure
    ENV['LANG'] = old
  end

  def build_tree(groups:, cts: nil, containers: false)
    tree = described_class.new('tank', color: false, containers:)

    allow(tree).to receive(:fetch) do
      tree.instance_variable_set(:@client, nil)
      tree.instance_variable_set(:@groups, groups)
      tree.instance_variable_set(:@cts, cts)
    end
    allow(tree).to receive(:cg_add_stats) do |data, *_args|
      data[:memory] = 1
      data[:cpu_us] = 2
      data
    end

    tree
  end

  it 'renders group-only trees including the root group' do
    tree = build_tree(groups: [{ name: '/', full_path: '/' }, { name: '/child', full_path: '/child' }])

    with_lang('C') { tree.render }

    branches = tree.instance_variable_get(:@groups).map { |grp| grp[:branch] }
    expect(branches.first).to eq('/')
    expect(branches.last).to include('child')
  end

  it 'filters groups without descendant containers when rendering container trees' do
    tree = build_tree(
      groups: [
        { name: '/', full_path: '/' },
        { name: '/empty', full_path: '/empty' },
        { name: '/used', full_path: '/used' }
      ],
      cts: [
        { group: '/used', group_path: '/used', id: 'ct1', pool: 'tank' }
      ],
      containers: true
    )

    tree.render

    names = tree.instance_variable_get(:@groups).map { |entry| entry[:shortname] }
    expect(names).to include('/', 'used', 'ct1')
    expect(names).not_to include('empty')
  end

  it 'switches decorations based on LANG' do
    tree = build_tree(groups: [{ name: '/', full_path: '/' }, { name: '/child', full_path: '/child' }])

    with_lang('C') do
      tree.render
      expect(tree.instance_variable_get(:@groups).last[:branch]).to start_with('`-- ')
    end

    tree = build_tree(groups: [{ name: '/', full_path: '/' }, { name: '/child', full_path: '/child' }])

    with_lang('en_US.UTF-8') do
      tree.render
      expect(tree.instance_variable_get(:@groups).last[:branch]).to start_with('└── ')
    end
  end
end
