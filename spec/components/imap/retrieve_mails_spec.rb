require "rails_helper"
require_dependency "email/imap_sync"

class ImapMock
  MailboxList = Struct.new(:attr, :delim, :name)
  FetchData = Struct.new(:seqno, :attr)

  attr_reader :responses

  def initialize(server, port, ssl, z = false, y = nil)
    @responses = {}
  end

  def login(username, password)
    @responses = {
      "CAPABILITY" => [
        ["IMAP4REV1", "UNSELECT", "IDLE", "NAMESPACE", "QUOTA", "ID", "XLIST", "CHILDREN", "X-GM-EXT-1", "UIDPLUS", "COMPRESS=DEFLATE", "ENABLE", "MOVE", "CONDSTORE", "ESEARCH", "UTF8=ACCEPT", "LIST-EXTENDED", "LIST-STATUS", "LITERAL-", "SPECIAL-USE", "APPENDLIMIT=35651584"]
      ]
    }
  end

  def list(filter, pattern)
    lists = [
      [ [:Hasnochildren], "/", "INBOX" ],
      [ [:Haschildren, :Noselect], "/", "[Gmail]" ],
      [ [:All, :Hasnochildren], "/", "[Gmail]/All Mail" ],
      [ [:Hasnochildren, :Trash], "/", "[Gmail]/Bin" ],
      [ [:Drafts, :Hasnochildren], "/", "[Gmail]/Drafts" ],
      [ [:Hasnochildren, :Important], "/", "[Gmail]/Important" ],
      [ [:Hasnochildren, :Sent], "/", "[Gmail]/Sent Mail" ],
      [ [:Hasnochildren, :Junk], "/", "[Gmail]/Spam" ],
      [ [:Flagged, :Hasnochildren], "/", "[Gmail]/Starred" ],
      [ [:Hasnochildren], "/", "test-label" ],
      [ [:Hasnochildren], "/", "Another test label" ]
    ]

    lists.map { |list|  MailboxList.new(*list) }
  end

  def examine(mailbox_name)
    @responses = { "UIDVALIDITY" => [11] }
  end

  def select(mailbox_name)
  end

  def uid_fetch(uids, capability)
    [
      FetchData.new(1,
        "UID" => 71,
        "X-GM-LABELS" => ["\\Important"],
        "FLAGS" => [:Seen],
        "RFC822" => <<~RFC822
Delivered-To: joffrey.jaffeux@discourse.org
MIME-Version: 1.0
From: John <john@free.fr>
Date: Sat, 31 Mar 2018 17:50:19 -0700
Subject: Testing email post
To: joffrey.jaffeux@discourse.org
Content-Type: text/plain; charset="UTF-8"

This is the email *body*. :smile:
        RFC822
      )
    ]
  end

  def uid_search(uid = "ALL")
    [71]
  end
end

describe Email::ImapSync do
  describe ".process" do
    let(:group) {
      Fabricate(:group,
        email_imap_server: "imap.gmail.com",
        email_imap_port: 993,
        email_imap_ssl: true,
        email_username: "xxx",
        email_password: "zzz"
      )
    }

    let(:mailbox) {
      Fabricate(:mailbox, name: "[Gmail]/All Mail", sync: true, group_id: group.id)
    }

    before do
      group.update!(mailboxes: [ mailbox ])
    end

    it "works" do
      sync_handler = Email::ImapSync.new(group, ImapMock)

      group.mailboxes.where(sync: true).each do |mailbox|
        sync_handler.process(mailbox)
      end

      expect(Topic.count).to eq(1)

      topic = Topic.last
      expect(topic.title).to eq("Testing email post")
    end
  end
end
