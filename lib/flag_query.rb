require 'ostruct'

module FlagQuery

  def self.plugin_post_custom_fields
    @plugin_post_custom_fields ||= {}
  end

  # Allow plugins to add custom fields to the flag views
  def self.register_plugin_post_custom_field(field, plugin)
    plugin_post_custom_fields[field] = plugin
  end

  def self.flagged_posts_report(current_user, opts = nil)
    opts ||= {}
    offset = opts[:offset] || 0
    per_page = opts[:per_page] || 25

    actions = flagged_post_actions(opts)

    guardian = Guardian.new(current_user)

    if !guardian.is_admin?
      actions = actions.where(
        'category_id IN (:allowed_category_ids) OR archetype = :private_message',
        allowed_category_ids: guardian.allowed_category_ids,
        private_message: Archetype.private_message
      )
    end

    total_rows = actions.count

    post_ids_relation = actions.limit(per_page)
      .offset(offset)
      .group(:post_id)
      .order('MIN(post_actions.created_at) DESC')

    if opts[:filter] != "old"
      post_ids_relation = PostAction.apply_minimum_visibility(post_ids_relation)
    end

    post_ids = post_ids_relation.pluck(:post_id).uniq

    posts = DB.query(<<~SQL, post_ids: post_ids)
      SELECT p.id,
             p.cooked as excerpt,
             p.raw,
             p.user_id,
             p.topic_id,
             p.post_number,
             p.reply_count,
             p.hidden,
             p.deleted_at,
             p.user_deleted,
             NULL as post_actions,
             NULL as post_action_ids,
             (SELECT created_at FROM post_revisions WHERE post_id = p.id AND user_id = p.user_id ORDER BY created_at DESC LIMIT 1) AS last_revised_at,
             (SELECT COUNT(*) FROM post_actions WHERE (disagreed_at IS NOT NULL OR agreed_at IS NOT NULL OR deferred_at IS NOT NULL) AND post_id = p.id)::int AS previous_flags_count
        FROM posts p
       WHERE p.id in (:post_ids)
    SQL

    post_lookup = {}
    user_ids = Set.new
    topic_ids = Set.new

    posts.each do |p|
      user_ids << p.user_id
      topic_ids << p.topic_id
      p.excerpt = Post.excerpt(p.excerpt)
      post_lookup[p.id] = p
    end

    post_actions = actions.order('post_actions.created_at DESC')
      .includes(related_post: { topic: { ordered_posts: :user } })
      .where(post_id: post_ids)

    all_post_actions = []

    post_actions.each do |pa|
      post = post_lookup[pa.post_id]

      if opts[:rest_api]
        post.post_action_ids ||= []
      else
        post.post_actions ||= []
      end

      # TODO: add serializer so we can skip this
      action = {
        id: pa.id,
        post_id: pa.post_id,
        user_id: pa.user_id,
        post_action_type_id: pa.post_action_type_id,
        created_at: pa.created_at,
        disposed_by_id: pa.disposed_by_id,
        disposed_at: pa.disposed_at,
        disposition: pa.disposition,
        related_post_id: pa.related_post_id,
        targets_topic: pa.targets_topic,
        staff_took_action: pa.staff_took_action
      }
      action[:name_key] = PostActionType.types.key(pa.post_action_type_id)

      if pa.related_post && pa.related_post.topic
        conversation = {}
        related_topic = pa.related_post.topic
        if response = related_topic.ordered_posts[0]
          conversation[:response] = {
            excerpt: excerpt(response.cooked),
            user_id: response.user_id
          }
          user_ids << response.user_id
          if reply = related_topic.ordered_posts[1]
            conversation[:reply] = {
              excerpt: excerpt(reply.cooked),
              user_id: reply.user_id
            }
            user_ids << reply.user_id
            conversation[:has_more] = related_topic.posts_count > 2
          end
        end

        action.merge!(permalink: related_topic.relative_url, conversation: conversation)
      end

      if opts[:rest_api]
        post.post_action_ids << action[:id]
        all_post_actions << action
      else
        post.post_actions << action
      end

      user_ids << pa.user_id
      user_ids << pa.disposed_by_id if pa.disposed_by_id
    end

    post_custom_field_names = []
    plugin_post_custom_fields.each do |field, plugin|
      post_custom_field_names << field if plugin.enabled?
    end

    post_custom_fields = Post.custom_fields_for_ids(post_ids, post_custom_field_names)

    # maintain order
    posts = post_ids.map { |id| post_lookup[id] }

    # TODO: add serializer so we can skip this
    posts.map! do |post|
      result = post.to_h
      if cfs = post_custom_fields[post.id]
        result[:custom_fields] = cfs
      end
      result
    end

    users = User.includes(:user_stat).where(id: user_ids.to_a).to_a
    User.preload_custom_fields(users, User.whitelisted_user_custom_fields(guardian))

    [
      posts,
      Topic.with_deleted.where(id: topic_ids.to_a).to_a,
      users,
      all_post_actions,
      total_rows
    ]
  end

  def self.flagged_post_actions(opts = nil)
    opts ||= {}

    post_actions = PostAction.flags
      .joins("INNER JOIN posts ON posts.id = post_actions.post_id")
      .joins("INNER JOIN topics ON topics.id = posts.topic_id")
      .joins("LEFT JOIN users ON users.id = posts.user_id")
      .where("posts.user_id > 0")

    if opts[:topic_id]
      post_actions = post_actions.where("topics.id = ?", opts[:topic_id])
    end

    if opts[:user_id]
      post_actions = post_actions.where("posts.user_id = ?", opts[:user_id])
    end

    if opts[:filter] == 'without_custom'
      return post_actions.where(
        'post_action_type_id' => PostActionType.flag_types_without_custom.values
      )
    end

    if opts[:filter] == "old"
      post_actions.where("post_actions.disagreed_at IS NOT NULL OR
                          post_actions.deferred_at IS NOT NULL OR
                          post_actions.agreed_at IS NOT NULL")
    else
      post_actions.active
        .where("posts.deleted_at" => nil)
        .where("topics.deleted_at" => nil)
    end

  end

  def self.flagged_topics
    results = DB.query(<<~SQL)
      SELECT pa.post_action_type_id,
        pa.post_id,
        p.topic_id,
        pa.created_at AS last_flag_at,
        p.user_id
      FROM post_actions AS pa
      INNER JOIN posts AS p ON pa.post_id = p.id
      INNER JOIN topics AS t ON t.id = p.topic_id
      WHERE pa.post_action_type_id IN (#{PostActionType.notify_flag_type_ids.join(',')})
        AND pa.disagreed_at IS NULL
        AND pa.deferred_at IS NULL
        AND pa.agreed_at IS NULL
        AND pa.deleted_at IS NULL
        AND p.user_id > 0
        AND p.deleted_at IS NULL
        AND t.deleted_at IS NULL
      ORDER BY pa.created_at DESC
    SQL

    ft_by_id = {}
    counts_by_post = {}
    user_ids = Set.new

    results.each do |pa|

      ft = ft_by_id[pa.topic_id] ||= OpenStruct.new(
        topic_id: pa.topic_id,
        flag_counts: {},
        user_ids: Set.new,
        last_flag_at: pa.last_flag_at,
        meets_minimum: false
      )

      counts_by_post[pa.post_id] ||= 0
      sum = counts_by_post[pa.post_id] += 1
      ft.meets_minimum = true if sum >= SiteSetting.min_flags_staff_visibility

      ft.flag_counts[pa.post_action_type_id] ||= 0
      ft.flag_counts[pa.post_action_type_id] += 1

      ft.user_ids << pa.user_id
      user_ids << pa.user_id
    end

    all_topics = Topic.where(id: ft_by_id.keys).to_a
    all_topics.each { |t| ft_by_id[t.id].topic = t }

    flagged_topics = ft_by_id.values.select { |ft| ft.meets_minimum }
    Topic.preload_custom_fields(all_topics, TopicList.preloaded_custom_fields)

    {
      flagged_topics: flagged_topics,
      users: User.where(id: user_ids)
    }
  end

  private

  def self.excerpt(cooked)
    excerpt = Post.excerpt(cooked, 200, keep_emoji_images: true)
    # remove the first link if it's the first node
    fragment = Nokogiri::HTML.fragment(excerpt)
    if fragment.children.first == fragment.css("a:first").first && fragment.children.first
      fragment.children.first.remove
    end
    fragment.to_html.strip
  end

end
