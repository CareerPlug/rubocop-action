require "json"
require "net/http"

module Github
  HttpError = Class.new(StandardError)

  class File
    RANGE_INFORMATION_LINE = /^@@ .+\+(?<line_number>\d+),/.freeze
    MODIFIED_LINE = /^\+(?!\+|\+)/.freeze
    NOT_REMOVED_LINE = /^[^-]/.freeze

    def initialize(file)
      @file = file
    end

    def path
      @file.fetch("filename")
    end

    def changed_lines
      patch = @file.fetch("patch") || ""
      line_number = 0
      patch.each_line.with_object([]) do |line_content, lines|
        case line_content
        when RANGE_INFORMATION_LINE
          line_number = Regexp.last_match[:line_number].to_i
        when MODIFIED_LINE
          lines << line_number
          line_number += 1
        when NOT_REMOVED_LINE
          line_number += 1
        end
      end
    end
  end

  CONNECTION = Net::HTTP.new("api.github.com", 443).tap { |http| http.use_ssl = true }
  REQUEST_METHOD_TO_CLASS = {
    get: Net::HTTP::Get,
    patch: Net::HTTP::Patch,
    post: Net::HTTP::Post,
    delete: Net::HTTP::Delete,
  }.freeze

  REQUEST_METHOD_TO_CLASS.each do |method, klass|
    define_singleton_method(method) do |path, params = nil|
      request(klass, path, params)
    end

    define_singleton_method("#{method}!") do |path, params = nil|
      response = request(klass, path, params)
      raise HttpError, "status: #{response.code}, body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body) if response.body
    end
  end

  PER_PAGE = 100
  # GitHub answered every 50-comment review with a 502 even though it created the review.
  REVIEW_COMMENTS_PER_REQUEST = 20

  def self.get_paginated!(path)
    separator = path.include?("?") ? "&" : "?"
    results = []
    1.step do |page|
      items = get!("#{path}#{separator}per_page=#{PER_PAGE}&page=#{page}")
      results.concat(items)
      break if items.length < PER_PAGE
    end
    results
  end

  # Submitted reviews can't be deleted, so the body outlives the inline comments we later
  # clean up. Keep it free of counts or anything else that goes stale.
  REVIEW_BODY = "Rubocop offenses".freeze

  # GitHub's secondary rate limit allows roughly 80 new comments a minute, counting each inline
  # comment in a review. When it kicks in we wait and retry, within a total budget per run.
  RATE_LIMIT_DEFAULT_WAIT = 60
  RATE_LIMIT_MAX_TOTAL_WAIT = 300

  # Posting each comment separately trips GitHub's secondary rate limit ("was submitted too quickly").
  # GitHub rejects a whole batch if any one comment is invalid, without saying which,
  # so a failure names the batch and its lines.
  #
  # A failed batch doesn't stop the later ones. Only rate-limit rejections are retried, since
  # nothing was created; a 5xx can arrive after GitHub created the review, so retrying it could
  # duplicate the review. The next run posts whatever is missing.
  def self.create_reviews!(owner_and_repository, pr_number, commit_id, comments)
    path = "/repos/#{owner_and_repository}/pulls/#{pr_number}/reviews"
    batches = comments.each_slice(REVIEW_COMMENTS_PER_REQUEST).to_a
    wait_left = RATE_LIMIT_MAX_TOTAL_WAIT

    failures = batches.each.with_index(1).filter_map do |batch, number|
      params = { commit_id: commit_id, event: "COMMENT", body: REVIEW_BODY, comments: batch }
      loop do
        response = post(path, params)
        break if response.is_a?(Net::HTTPSuccess)

        wait = rate_limit_wait(response)
        raise HttpError, "status: #{response.code}, body: #{response.body}" unless wait && wait <= wait_left

        puts "GitHub rate limit hit on review batch #{number} of #{batches.length}, retrying in #{wait}s"
        wait_left -= wait
        pause(wait)
      end
      nil
    rescue HttpError => e
      lines = batch.map { |comment| "#{comment.fetch(:path)}:#{comment.fetch(:line)}" }.join(", ")
      "Posting review batch #{number} of #{batches.length} failed (#{lines}): #{e.message}"
    end

    raise HttpError, failures.join("\n") if failures.any?
  end

  # Seconds to wait before retrying a rate-limited response, or nil if it wasn't rate limited.
  def self.rate_limit_wait(response)
    rate_limited = response.code == "429" ||
      (response.code == "403" && response.body.to_s.include?("rate limit"))
    return unless rate_limited

    Integer(response["retry-after"].to_s, exception: false) || RATE_LIMIT_DEFAULT_WAIT
  end

  def self.pause(seconds)
    sleep seconds
  end

  def self.pull_request_ruby_files(owner_and_repository, pr_number)
    get_paginated!("/repos/#{owner_and_repository}/pulls/#{pr_number}/files")
      .reject { |file| file.fetch("status") == "removed" }
      .select { |file| file.fetch("filename").end_with?(".rb") }
      .map { |file| File.new(file) }
  end

  def self.request(request_class, path, params = nil)
    request = request_class.new(path)
    request.content_type = "application/json"
    request.body = params&.to_json
    request["Authorization"] = "Bearer #{ENV.fetch('GITHUB_TOKEN')}"
    request["Accept"] = "application/vnd.github.v3+json"

    CONNECTION.request(request)
  end
end
