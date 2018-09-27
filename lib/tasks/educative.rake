require "redis"

namespace :educative do
  desc "TODO"
  task flush_redis: :environment do
	redis = Redis.new(host: "127.0.0.1", port: 6379)
	redis.flushall()
  end

  task flush_categories: :environment do
		Category.delete_all
		Rake::Task["educative:flush_redis"].invoke()
  end

  task flush_topics: :environment do
		Topic.delete_all
		Rake::Task["educative:flush_redis"].invoke()
  end

  task flush_posts: :environment do
		Post.delete_all
		Rake::Task["educative:flush_redis"].invoke()
  end

  task flush_all: :environment do
		Rake::Task["educative:flush_categories"].invoke()
		Rake::Task["educative:flush_topics"].invoke()
		Rake::Task["educative:flush_posts"].invoke()
		Rake::Task["educative:flush_redis"].invoke()
  end
end
