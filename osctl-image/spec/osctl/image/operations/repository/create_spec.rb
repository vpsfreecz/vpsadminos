# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Repository::Create do
  let(:repo) { instance_double(OsCtl::Repo::Local::Repository, exist?: exists, create: nil) }
  let(:exists) { false }

  before do
    allow(OsCtl::Repo::Local::Repository).to receive(:new).with('/repo').and_return(repo)
    allow(FileUtils).to receive(:mkpath)
  end

  it 'creates the repository when it does not exist' do
    expect(described_class.new('/repo').execute).to be(true)
    expect(FileUtils).to have_received(:mkpath).with('/repo')
    expect(repo).to have_received(:create)
  end

  it 'does nothing destructive when the repository already exists' do
    allow(repo).to receive(:exist?).and_return(true)

    described_class.new('/repo').execute

    expect(FileUtils).not_to have_received(:mkpath)
    expect(repo).not_to have_received(:create)
  end
end
