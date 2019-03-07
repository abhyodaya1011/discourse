require_dependency 'email/sender'

module Jobs

  class GroupSmtpEmail < Jobs::Base
    include Skippable

    sidekiq_options queue: 'low'

    def execute(args)
      group = Group.find_by(id: args[:group_id])
      email = args[:email]
      topic = Topic.find_by(id: args[:topic_id])
      post = Post.find_by(id: args[:post_id])

      message = GroupSmtpMailer.send_mail(group, email, topic, post)
      Email::Sender.new(message, :group_smtp).send
    end

  end

end
