require "minitest/autorun"
require_relative "../lib/github"

class GithubTest < Minitest::Test
  def test_get_paginated_follows_pages_until_a_short_page
    pages = {
      "/repos/o/r/pulls/1/comments?per_page=100&page=1" => Array.new(100) { |i| { "id" => i } },
      "/repos/o/r/pulls/1/comments?per_page=100&page=2" => [{ "id" => 100 }],
    }
    requested = []

    stub_github(:get!, ->(path) { pages.fetch(path).tap { requested << path } }) do
      comments = Github.get_paginated!("/repos/o/r/pulls/1/comments")

      assert_equal 101, comments.length
      assert_equal pages.keys, requested
    end
  end

  def test_get_paginated_requests_one_extra_page_when_the_last_page_is_full
    pages = {
      "/repos/o/r/pulls/1/comments?per_page=100&page=1" => Array.new(100) { |i| { "id" => i } },
      "/repos/o/r/pulls/1/comments?per_page=100&page=2" => [],
    }

    stub_github(:get!, ->(path) { pages.fetch(path) }) do
      assert_equal 100, Github.get_paginated!("/repos/o/r/pulls/1/comments").length
    end
  end

  def test_get_paginated_appends_to_an_existing_query_string
    requested = []

    stub_github(:get!, ->(path) { [].tap { requested << path } }) do
      Github.get_paginated!("/repos/o/r/pulls/1/comments?sort=created")
    end

    assert_equal ["/repos/o/r/pulls/1/comments?sort=created&per_page=100&page=1"], requested
  end

  def test_create_reviews_batches_comments_into_reviews
    comments = Array.new(120) { |i| { path: "a.rb", line: i + 1, side: "RIGHT", body: "offense #{i}" } }
    posts = []

    stub_github(:post!, ->(path, params) { posts << [path, params] }) do
      Github.create_reviews!("o/r", 1, "abc123", comments)
    end

    assert_equal [20, 20, 20, 20, 20, 20], posts.map { |_, params| params.fetch(:comments).length }
    assert_equal comments, posts.flat_map { |_, params| params.fetch(:comments) }

    path, params = posts.first
    assert_equal "/repos/o/r/pulls/1/reviews", path
    assert_equal "COMMENT", params.fetch(:event)
    assert_equal "abc123", params.fetch(:commit_id)
    assert_equal [Github::REVIEW_BODY], posts.map { |_, params| params.fetch(:body) }.uniq
  end

  def test_create_reviews_names_the_failed_batch_and_its_lines
    comments = Array.new(30) { |i| { path: "a.rb", line: i + 1, side: "RIGHT", body: "offense #{i}" } }
    posts = 0
    post = lambda do |_path, _params|
      posts += 1
      raise Github::HttpError, "status: 422" if posts == 2
    end

    error = stub_github(:post!, post) do
      assert_raises(Github::HttpError) { Github.create_reviews!("o/r", 1, "abc123", comments) }
    end

    assert_match "batch 2 of 2", error.message
    assert_match "a.rb:21, a.rb:22", error.message
    assert_match "a.rb:30", error.message
    refute_match "a.rb:20,", error.message
    assert_match "status: 422", error.message
  end

  def test_create_reviews_keeps_posting_after_a_failed_batch
    comments = Array.new(60) { |i| { path: "a.rb", line: i + 1, side: "RIGHT", body: "offense #{i}" } }
    attempted = []
    post = lambda do |_path, params|
      attempted << params.fetch(:comments).first.fetch(:line)
      raise Github::HttpError, "status: 502" if attempted.length == 1
    end

    error = stub_github(:post!, post) do
      assert_raises(Github::HttpError) { Github.create_reviews!("o/r", 1, "abc123", comments) }
    end

    assert_equal [1, 21, 41], attempted
    assert_match "batch 1 of 3", error.message
    refute_match "batch 2", error.message
  end

  def test_create_reviews_reports_every_failed_batch
    comments = Array.new(60) { |i| { path: "a.rb", line: i + 1, side: "RIGHT", body: "offense #{i}" } }

    error = stub_github(:post!, ->(_path, _params) { raise Github::HttpError, "status: 502" }) do
      assert_raises(Github::HttpError) { Github.create_reviews!("o/r", 1, "abc123", comments) }
    end

    assert_equal ["batch 1 of 3", "batch 2 of 3", "batch 3 of 3"], error.message.scan(/batch \d of \d/)
  end

  private

  def stub_github(method_name, implementation)
    original = Github.method(method_name)
    Github.define_singleton_method(method_name) { |*args| implementation.call(*args) }
    yield
  ensure
    Github.define_singleton_method(method_name, original)
  end
end
