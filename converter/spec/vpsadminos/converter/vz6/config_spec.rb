# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'vpsadminos-converter/vz6/config'
require 'vpsadminos-converter/vz6/config_item'

RSpec.describe VpsAdminOS::Converter::Vz6::Config do
  def parse_config(text)
    described_class.new('101', StringIO.new(text))
  end

  it 'ignores comments and blank lines while parsing quoted and unquoted values' do
    config = parse_config(<<~CFG)
      # comment

      HOSTNAME="demo.example"
      VE_LAYOUT=simfs
      NETFILTER=full
    CFG

    expect(config['HOSTNAME'].value).to eq('demo.example')
    expect(config['VE_LAYOUT'].value).to eq('simfs')
    expect(config['NETFILTER'].value).to eq('full')
  end

  it 'parses empty quoted values as empty strings' do
    config = parse_config("HOSTNAME=\"\"\n")

    expect(config['HOSTNAME'].value).to eq('')
  end

  it 'returns config items and marks consumed values' do
    config = parse_config("HOSTNAME=demo\n")

    expect(config['HOSTNAME'].consumed?).to be(false)
    expect(config.consume('HOSTNAME')).to eq('demo')
    expect(config['HOSTNAME'].consumed?).to be(true)
  end

  it 'warns about unknown lines without crashing' do
    stderr = capture_stderr do
      config = parse_config("this is not valid\nHOSTNAME=demo\n")

      expect(config['HOSTNAME'].value).to eq('demo')
    end

    expect(stderr).to include("Unknown line 'this is not valid\n'")
  end
end
