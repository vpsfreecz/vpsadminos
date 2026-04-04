# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Lib do
  it 'loads the full library and remaining entrypoints' do
    expect { require 'libosctl' }.not_to raise_error
    expect(OsCtl::Lib::VERSION).to be_a(String)
    expect(OsCtl::Lib::Sys).to be_a(Class)
    expect(OsCtl::Lib::Exporter::Base).to be_a(Class)
    expect(OsCtl::Lib::Exporter::Tar).to be_a(Class)
    expect(OsCtl::Lib::Exporter::Zfs).to be_a(Class)
    expect(OsCtl::Lib::Cli::Completion::Bash).to be_a(Class)
    expect(OsCtl::Lib::Zfs::ObjsetStats).to respond_to(:read_pool)
    expect(OsCtl::Lib::Zfs::ObjsetStats).to respond_to(:read_pools)
  end
end
