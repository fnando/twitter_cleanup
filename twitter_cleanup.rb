# frozen_string_literal: true

require "bundler/setup"

require "json"
require "twitter"

class TwitterCleanup
  YEAR_IN_SECONDS = 86_400 * 366

  def tweet_ttl
    @tweet_ttl ||= Integer(ENV.fetch("TWEET_TTL", YEAR_IN_SECONDS))
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
    time = error.rate_limit.reset_in + 1
    puts "=> Error: too many requests (wait #{time}s)"

    sleep error.rate_limit.reset_in + 1
    retry
  end

  def timeline_options
    {
      count: 3200,
      trim_user: true,
      include_rts: true,
      exclude_replies: false
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
    process_favorites

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

  def process_favorites
    loop do
      since_id = favorite_ids.max || 1
      new_favorite_ids = client
                         .favorites(client.user, since_id: since_id)
                         .map(&:id)

      break if new_favorite_ids.empty?

      favorite_ids.push(*new_favorite_ids)
    rescue Twitter::Error::TooManyRequests => error
      time = error.rate_limit.reset_in + 1
      puts "=> Error: too many requests (wait #{time}s)"
      sleep error.rate_limit.reset_in + 1
      retry
    end
  end

  def process_tweet(tweet)
    tweet_ids << tweet.id

    return if favorite_ids.include?(tweet.id)
    return if tweet.created_at > Time.now.utc - tweet_ttl

    client.destroy_status(tweet)
  end

  def tweet_ids
    @tweet_ids ||= []
  end

  def favorite_ids
    @favorite_ids ||= []
  end
end

TwitterCleanup.new.call
