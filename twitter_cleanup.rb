# frozen_string_literal: true

require "bundler/setup"

require "json"
require "twitter"

class TwitterCleanup
  YEAR_IN_SECONDS = 86_400 * 365

  def keybase_verification_id
    ENV["KEYBASE_VERIFICATION_ID"]
  end

  def tweet_ttl
    @tweet_ttl ||= ENV.fetch("TWEET_TTL", YEAR_IN_SECONDS)
  end

  def client
    @client ||= Twitter::REST::Client.new do |config|
      config.consumer_key = ENV.fetch("TWITTER_CONSUMER_KEY")
      config.consumer_secret = ENV.fetch("TWITTER_CONSUMER_SECRET")
      config.access_token = ENV.fetch("TWITTER_ACCESS_TOKEN")
      config.access_token_secret = ENV.fetch("TWITTER_ACCESS_TOKEN_SECRET")
    end
  end

  def user_name
    @user_name ||= client.user.screen_name
  end

  def destroy(id)
    client.destroy_status(id)
  rescue Twitter::Error::TooManyRequests => error
    puts "=> Error: too many requests (wait #{time}s)"

    sleep error.rate_limit.reset_in + 1
    retry
  end

  def timeline_options
    {
      count: 3200,
      trim_user: true,
      include_rts: true,
      exclude_replies: true
    }.tap do |options|
      options[:max_id] = tweet_ids.min if tweet_ids.any?
    end
  end

  def timeline
    client.user_timeline(user_name, timeline_options).map do |tweet|
      next tweet unless tweet.truncated?

      client.status(tweet.id)
    rescue Twitter::Error::TooManyRequests => error
      time = error.rate_limit.reset_in + 1

      puts "=> Error: too many requests (wait #{time}s)"

      sleep time
      retry
    end
  end

  def call
    loop do
      tweets = timeline.reject {|tweet| tweet_ids.include?(tweet.id) }

      break if tweets.empty?

      tweets.each {|tweet| process_tweet(tweet) }
    end
  rescue Twitter::Error::TooManyRequests => error
    time = error.rate_limit.reset_in + 1

    puts "=> Error: too many requests (wait #{time}s)"

    sleep time
    retry
  end

  def process_tweet(tweet)
    tweet_ids << tweet.id

    return if keybase_verification_id.to_i == tweet.id
    return if tweet.created_at > Time.now.utc - tweet_ttl

    client.destroy_status(tweet)
  end

  def tweet_ids
    @tweet_ids ||= []
  end
end

TwitterCleanup.new.call
