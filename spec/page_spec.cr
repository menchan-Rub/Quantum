require "spec"
require "./spec_helper"

describe QuantumCore::Page do
  before do
    @dispatcher = QuantumEvents::EventDispatcher.new
    @scheduler = QuantumCore::ResourceScheduler.new(@dispatcher)
    @page = QuantumCore::Page.new(1_u64, @dispatcher, @scheduler)
  end

  it "初期化時のデフォルト値を持つこと" do
    @page.id.should eq(1_u64)
    @page.title.should eq("New Tab")
    @page.url.should be_nil
    @page.load_state.should eq(QuantumCore::Page::LoadState::Idle)
  end

  it "有効なURLへのナビゲーションでLoading状態になること" do
    @page.navigate("http://example.com", true, false)
    @page.pending_url.should_not be_nil
    @page.load_state.should eq(QuantumCore::Page::LoadState::Loading)
  end

  it "無効なURLのナビゲーションでFailed状態になること" do
    @page.navigate("not-a-url", true, false)
    @page.load_state.should eq(QuantumCore::Page::LoadState::Failed)
  end
end 