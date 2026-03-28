# frozen_string_literal: true

require 'erb'

require 'osctld/erb_template'

RSpec.describe OsCtld::ErbTemplate do
  let(:template) { ERB.new('value=<%= value %>; call=<%= callable(3) %>', trim_mode: '-') }

  before do
    allow(OsCtld::ErbTemplateCache).to receive(:[]).and_return(template.clone)
  end

  it 'renders plain, proc, and method values' do
    helper = Class.new do
      def triple(value)
        value * 3
      end
    end.new

    rendered = described_class.render(
      'sample',
      value: 'plain',
      callable: helper.method(:triple)
    )

    expect(rendered).to eq('value=plain; call=9')
  end

  it 'evaluates proc variables lazily' do
    rendered = described_class.render(
      'sample',
      value: proc { 'dynamic' },
      callable: proc { |value| value + 1 }
    )

    expect(rendered).to eq('value=dynamic; call=4')
  end

  it 'renders to a temporary file and renames it into place' do
    with_tmpdir do |dir|
      path = File.join(dir, 'config')

      described_class.render_to('sample', { value: 'plain', callable: proc { |value| value } }, path)

      expect(File.read(path)).to eq('value=plain; call=3')
      expect(File.exist?("#{path}.new")).to be(false)
    end
  end

  it 'replaces the file when content changes' do
    with_tmpdir do |dir|
      path = File.join(dir, 'config')
      File.write(path, 'old')

      described_class.render_to_if_changed(
        'sample',
        { value: 'new', callable: proc { |value| value } },
        path
      )

      expect(File.read(path)).to eq('value=new; call=3')
      expect(File.exist?("#{path}.new")).to be(false)
    end
  end

  it 'removes the temporary file and chmods the existing file when content is identical' do
    with_tmpdir do |dir|
      path = File.join(dir, 'config')
      File.write(path, 'value=same; call=3')
      File.chmod(0o600, path)

      described_class.render_to_if_changed(
        'sample',
        { value: 'same', callable: proc { |value| value } },
        path,
        perm: 0o644
      )

      expect(File.read(path)).to eq('value=same; call=3')
      expect(File.exist?("#{path}.new")).to be(false)
      expect(File.stat(path).mode & 0o777).to eq(0o644)
    end
  end
end
