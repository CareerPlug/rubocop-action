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

    assert_equal [50, 50, 20], posts.map { |_, params| params.fetch(:comments).length }
    assert_equal comments, posts.flat_map { |_, params| params.fetch(:comments) }

    path, params = posts.first
    assert_equal "/repos/o/r/pulls/1/reviews", path
    assert_equal "COMMENT", params.fetch(:event)
    assert_equal "abc123", params.fetch(:commit_id)
    refute_empty params.fetch(:body)
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
