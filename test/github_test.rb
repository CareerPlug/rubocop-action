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
    comments = review_comments(120)
    posts = []

    stub_github(:post, ->(path, params) { posts << [path, params] && http_response(200) }) do
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
    responses = [http_response(200), http_response(422, '{"message":"Unprocessable"}')]

    error = stub_github(:post, ->(_path, _params) { responses.shift }) do
      assert_raises(Github::HttpError) { Github.create_reviews!("o/r", 1, "abc123", review_comments(30)) }
    end

    assert_match "batch 2 of 2", error.message
    assert_match "a.rb:21, a.rb:22", error.message
    assert_match "a.rb:30", error.message
    refute_match "a.rb:20,", error.message
    assert_match "status: 422", error.message
  end

  def test_create_reviews_keeps_posting_after_a_failed_batch_without_retrying_it
    attempted = []
    post = lambda do |_path, params|
      attempted << params.fetch(:comments).first.fetch(:line)
      attempted.length == 1 ? http_response(502, '{"message":"Server Error"}') : http_response(200)
    end

    error = stub_github(:post, post) do
      assert_raises(Github::HttpError) { Github.create_reviews!("o/r", 1, "abc123", review_comments(60)) }
    end

    assert_equal [1, 21, 41], attempted
    assert_match "batch 1 of 3", error.message
    refute_match "batch 2", error.message
  end

  def test_create_reviews_reports_every_failed_batch
    error = stub_github(:post, ->(_path, _params) { http_response(502) }) do
      assert_raises(Github::HttpError) { Github.create_reviews!("o/r", 1, "abc123", review_comments(60)) }
    end

    assert_equal ["batch 1 of 3", "batch 2 of 3", "batch 3 of 3"], error.message.scan(/batch \d of \d/)
  end

  def test_create_reviews_waits_and_retries_a_rate_limited_batch
    responses = [
      http_response(200),
      http_response(403, '{"message":"You have exceeded a secondary rate limit"}', "retry-after" => "42"),
      http_response(200),
    ]
    attempted = []
    pauses = []
    post = ->(_path, params) { attempted << params.fetch(:comments).first.fetch(:line) && responses.shift }

    stub_github(:post, post) do
      stub_github(:pause, ->(seconds) { pauses << seconds }) do
        Github.create_reviews!("o/r", 1, "abc123", review_comments(40))
      end
    end

    assert_equal [1, 21, 21], attempted
    assert_equal [42], pauses
  end

  def test_create_reviews_waits_a_minute_when_github_gives_no_retry_after
    responses = [http_response(429), http_response(200)]
    pauses = []

    stub_github(:post, ->(_path, _params) { responses.shift }) do
      stub_github(:pause, ->(seconds) { pauses << seconds }) do
        Github.create_reviews!("o/r", 1, "abc123", review_comments(10))
      end
    end

    assert_equal [Github::RATE_LIMIT_DEFAULT_WAIT], pauses
  end

  def test_create_reviews_stops_retrying_once_the_wait_budget_is_spent
    pauses = []
    rate_limited = -> { http_response(403, '{"message":"secondary rate limit"}') }

    error = stub_github(:post, ->(_path, _params) { rate_limited.call }) do
      stub_github(:pause, ->(seconds) { pauses << seconds }) do
        assert_raises(Github::HttpError) { Github.create_reviews!("o/r", 1, "abc123", review_comments(60)) }
      end
    end

    assert_equal Github::RATE_LIMIT_MAX_TOTAL_WAIT, pauses.sum
    assert_equal ["batch 1 of 3", "batch 2 of 3", "batch 3 of 3"], error.message.scan(/batch \d of \d/)
  end

  def test_create_reviews_does_not_retry_a_403_that_is_not_a_rate_limit
    posts = 0
    post = lambda do |_path, _params|
      posts += 1
      http_response(403, '{"message":"Resource not accessible by integration"}')
    end

    stub_github(:post, post) do
      stub_github(:pause, ->(_seconds) { flunk "should not wait" }) do
        assert_raises(Github::HttpError) { Github.create_reviews!("o/r", 1, "abc123", review_comments(10)) }
      end
    end

    assert_equal 1, posts
  end

  private

  def review_comments(count)
    Array.new(count) { |i| { path: "a.rb", line: i + 1, side: "RIGHT", body: "offense #{i}" } }
  end

  def http_response(code, body = "{}", headers = {})
    Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "").tap do |response|
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
      headers.each { |name, value| response[name] = value }
    end
  end

  def stub_github(method_name, implementation)
    original = Github.method(method_name)
    Github.define_singleton_method(method_name) { |*args| implementation.call(*args) }
    yield
  ensure
    Github.define_singleton_method(method_name, original)
  end
end
