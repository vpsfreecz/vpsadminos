# frozen_string_literal: true

require 'osctld/erb_template_cache'

RSpec.describe OsCtld::ErbTemplateCache do
  it 'loads erb templates from OsCtld.template_dir and returns independent clones' do
    with_tmpdir do |dir|
      tpl_path = File.join(dir, 'test')
      Dir.mkdir(tpl_path)
      File.write(File.join(tpl_path, 'hello.erb'), 'hello <%= name %>')

      unless OsCtld.respond_to?(:template_dir)
        OsCtld.define_singleton_method(:template_dir) { nil }
      end
      allow(OsCtld).to receive(:template_dir).and_return(dir)

      described_class.instance.load

      template_a = described_class['test/hello']
      template_b = described_class['test/hello']

      name = 'world'
      expect(template_a.result(binding)).to eq('hello world')
      expect(template_b.result(binding)).to eq('hello world')
      expect(template_a).not_to equal(template_b)
    end
  end
end
