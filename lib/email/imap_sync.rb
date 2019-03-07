require "net/imap"
require_dependency "imap_gmail_patch"

class ImapMailboxStatusParser
  def self.parse(status)
    parser = new(status)
    return parser.to_h
  end

  def initialize(status)
    @status = status
  end

  def to_h
    {
      uid_validity: @status["UIDVALIDITY"][-1]
    }
  end
end

module Email
  class ImapSync
    attr_reader :capability
    attr_reader :status

    def initialize(group, imap_service = Net::IMAP)
      @group = group
      @imap = connect(imap_service, group)
      @remote_mailboxes = @imap.list('', '*').map(&:name)
      @labels = extract_labels(@remote_mailboxes)

      # TODO: Surround all relevant places with `if @is_gmail`.
      @is_gmail = group.email_imap_server == "imap.gmail.com"
      apply_gmail_patch(@imap) if @is_gmail
    end

    def process(mailbox)
      @mailbox = mailbox

      # TODO: Server-to-client sync:
      #       - check mailbox validity
      #       - discover changes to old messages
      #       - fetch new messages
      @imap.examine(mailbox.name)

      @status = ImapMailboxStatusParser.parse(@imap.responses)

      # Important operations on mailbox may invalidate mailbox and change
      # `UIDVALIDITY` attribute.
      #
      # In this case, mailbox must be resynchronized from scratch.
      if @status[:uid_validity] != mailbox.uid_validity
        Rails.logger.warn("UIDVALIDITY does not match, invalidating IMAP cache and resync emails.")
        mailbox.last_seen_uid = 0
      end

      # Fetching UIDs of already synchronized and newly arrived emails.
      # Some emails may be considered newly arrived even though they have been
      # previously processed if the mailbox has been invalidated (UIDVALIDITY
      # changed).
      if mailbox.last_seen_uid == 0
        old_uids = []
        new_uids = @imap.uid_search("ALL")
      else
        old_uids = @imap.uid_search("UID 1:#{mailbox.last_seen_uid}")
        new_uids = @imap.uid_search("UID #{mailbox.last_seen_uid + 1}:*")
      end

      if old_uids.present?
        emails = @imap.uid_fetch(old_uids, ["UID", "FLAGS", "X-GM-LABELS"])

        emails.each do |email|
          incoming_email = IncomingEmail.find_by(imap_uid_validity: @status[:uid_validity], imap_uid: email.attr["UID"])
          update_topic(email, incoming_email)
        end
      end

      if new_uids.present?
        emails = @imap.uid_fetch(new_uids, ["UID", "FLAGS", "X-GM-LABELS", "RFC822"])
        emails.each do |email|
          begin
            receiver = Email::Receiver.new(email.attr["RFC822"],
              destinations: [{ type: :group, obj: @group }],
              uid_validity: @status[:uid_validity],
              uid: email.attr["UID"]
            )
            receiver.process!
            update_topic(email, receiver.incoming_email)

            mailbox.last_seen_uid = email.attr["UID"]
          rescue Email::Receiver::ProcessingError => e
            p e
          end
        end
      end

      mailbox.uid_validity = @status[:uid_validity]
      mailbox.save!

      @imap.select(mailbox.name)

      # TODO: Client-to-server sync:
      #       - sending emails using SMTP
      #       - sync labels
      IncomingEmail.where(imap_sync: true).each do |incoming_email|
        update_email(incoming_email)
      end
    end

    def disconnect
      @imap.logout
      @imap.disconnect
    end

    def update_topic(email, incoming_email)
      return if incoming_email&.post&.post_number != 1 || incoming_email.imap_sync
      labels = email.attr["X-GM-LABELS"]
      flags = email.attr["FLAGS"]
      topic = incoming_email.topic

      # Sync archived status of topic.
      old_archived = topic.group_archived_messages.length > 0
      new_archived = !labels.include?("\\Inbox")
      if old_archived && !new_archived
        GroupArchivedMessage.move_to_inbox!(@group.id, topic)
      elsif !old_archived && new_archived
        GroupArchivedMessage.archive!(@group.id, topic)
      end

      # Sync email flags and labels with topic tags.
      tags = [ to_tag(@mailbox.name), flags.include?(:Seen) && "seen" ]
      labels.each { |label| tags << to_tag(label) }
      tags.reject!(&:blank?)

      # TODO: Optimize tagging.
      topic.tags = []
      DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), tags)
    end

    def update_email(incoming_email)
      return if incoming_email&.post&.post_number != 1 || !incoming_email.imap_sync
      return unless email = @imap.uid_fetch(incoming_email.imap_uid, ["FLAGS", "X-GM-LABELS"]).first
      # incoming_email.update(imap_sync: false)

      labels = email.attr["X-GM-LABELS"]
      flags = email.attr["FLAGS"]
      topic = incoming_email.topic

      # Sync topic status and labels with email flags and labels.
      tags = topic.tags.pluck(:name)
      new_flags = tags.map { |tag| tag_to_flag(tag) }.reject(&:blank?)
      new_labels = tags.map { |tag| tag_to_label(tag) }.reject(&:blank?)
      new_labels << "\\Inbox" if topic.group_archived_messages.length == 0
      store(incoming_email.imap_uid, "FLAGS", flags, new_flags)
      store(incoming_email.imap_uid, "X-GM-LABELS", labels, new_labels)
    end

    def store(uid, attribute, old_set, new_set)
      additions = new_set.reject { |val| old_set.include?(val) }
      @imap.uid_store(uid, "+#{attribute}", additions) if additions.length > 0
      removals = old_set.reject { |val| new_set.include?(val) }
      @imap.uid_store(uid, "-#{attribute}", removals) if removals.length > 0
    end

    def tag_to_flag(tag)
      :Seen if tag == "seen"
    end

    def tag_to_label(tag)
      @labels[tag]
    end

    private

    def to_tag(label)
      label = label.to_s.gsub("[Gmail]/", "")
      label = DiscourseTagging.clean_tag(label.to_s)

      label if label != "all-mail" && label != "inbox" && label != "sent"
    end

    def extract_labels(mailboxes)
      labels = {}

      mailboxes.each do |name|
        if tag = to_tag(name)
          labels[tag] = name
        end
      end

      labels["important"] = "\\Important"

      labels
    end

    def connect(imap_service, group)
      imap = imap_service.new(
        group.email_imap_server,
        group.email_imap_port,
        group.email_imap_ssl,
        nil,
        false
      )
      imap.login(group.email_username, group.email_password)
      imap
    end
  end

end
