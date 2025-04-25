require "spec"
require "./spec_helper"

describe QuantumCore::ResourceScheduler do
  before do
    @dispatcher = QuantumEvents::EventDispatcher.new
    @scheduler = QuantumCore::ResourceScheduler.new(@dispatcher, 2)
  end

  it "リクエストIDがインクリメントされること" do
    id1 = @scheduler.request_main_resource(1_u64, URI.parse("http://example.com"))
    id2 = @scheduler.request_main_resource(1_u64, URI.parse("http://example.com"))
    id2.should eq(id1 + 1)
  end

  it "同時実行数制限を超えないこと" do
    # デフォルト最大2、3つ目は待機状態となる
    id1 = @scheduler.request_main_resource(1_u64, URI.parse("http://example.com"))
    id2 = @scheduler.request_main_resource(1_u64, URI.parse("http://example.com"))
    id3 = @scheduler.request_main_resource(1_u64, URI.parse("http://example.com"))
    # active_requests は2件のはず
    @scheduler.instance_variable_get("@active_requests").size.should eq(2)
  end
end 