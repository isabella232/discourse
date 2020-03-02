# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BookmarkManager do
  let(:user) { Fabricate(:user) }

  let(:reminder_type) { 'tomorrow' }
  let(:reminder_at) { (Time.now.utc + 1.day).iso8601 }
  fab!(:post) { Fabricate(:post) }
  let(:name) { 'Check this out!' }

  subject { described_class.new(user) }

  describe ".create" do
    it "creates the bookmark for the user" do
      subject.create(post_id: post.id, name: name)
      bookmark = Bookmark.find_by(user: user)

      expect(bookmark.post_id).to eq(post.id)
      expect(bookmark.topic_id).to eq(post.topic_id)
    end

    context "when a reminder time + type is provided" do
      it "saves the values correctly and enqueues a reminder job" do
        Jobs.expects(:enqueue_at).with(reminder_at, :bookmark_reminder, has_key(:bookmark_id))
        subject.create(post_id: post.id, name: name, reminder_type: reminder_type, reminder_at: reminder_at)
        bookmark = Bookmark.find_by(user: user)

        expect(bookmark.reminder_at).to eq(reminder_at)
        expect(bookmark.reminder_type).to eq(Bookmark.reminder_types[:tomorrow])
      end
    end

    context "when the reminder type is at_desktop" do
      let(:reminder_type) { 'at_desktop' }
      let(:reminder_at) { nil }

      it "does not enqueue the job; this is a special case which needs client-side logic" do
        Jobs.expects(:enqueue_at).never
        subject.create(post_id: post.id, name: name, reminder_type: reminder_type, reminder_at: reminder_at)
        bookmark = Bookmark.find_by(user: user)

        expect(bookmark.reminder_at).to eq(reminder_at)
        expect(bookmark.reminder_type).to eq(Bookmark.reminder_types[:at_desktop])
      end
    end

    context "when the bookmark already exists for the user & post" do
      before do
        Bookmark.create(post: post, user: user, topic: post.topic)
      end

      it "adds an error to the manager" do
        subject.create(post_id: post.id)
        expect(subject.errors.full_messages).to include(I18n.t("bookmarks.errors.already_bookmarked_post"))
      end
    end

    context "when the reminder time is not provided when it needs to be" do
      let(:reminder_at) { nil }
      it "adds an error to the manager" do
        subject.create(post_id: post.id, name: name, reminder_type: reminder_type, reminder_at: reminder_at)
        expect(subject.errors.full_messages).to include(
          "Reminder at " + I18n.t("bookmarks.errors.time_must_be_provided", reminder_type: I18n.t("bookmarks.reminders.at_desktop"))
        )
      end
    end

    context "when the reminder time is in the past" do
      let(:reminder_at) { (Time.now.utc - 10.days).iso8601 }
      it "adds an error to the manager" do
        subject.create(post_id: post.id, name: name, reminder_type: reminder_type, reminder_at: reminder_at)
        expect(subject.errors.full_messages).to include(I18n.t("bookmarks.errors.cannot_set_past_reminder"))
      end
    end

    context "when the reminder time is far-flung (> 10 years from now)" do
      let(:reminder_at) { (Time.now.utc + 11.years).iso8601 }
      it "adds an error to the manager" do
        subject.create(post_id: post.id, name: name, reminder_type: reminder_type, reminder_at: reminder_at)
        expect(subject.errors.full_messages).to include(I18n.t("bookmarks.errors.cannot_set_reminder_in_distant_future"))
      end
    end
  end

  describe ".destroy" do
    let!(:bookmark) { Fabricate(:bookmark, user: user, post: post) }
    it "deletes the existing bookmark" do
      subject.destroy(bookmark.id)
      expect(Bookmark.exists?(id: bookmark.id)).to eq(false)
    end

    context "if the bookmark is belonging to some other user" do
      let!(:bookmark) { Fabricate(:bookmark, user: Fabricate(:admin), post: post) }
      it "raises an invalid access error" do
        expect { subject.destroy(bookmark.id) }.to raise_error(Discourse::InvalidAccess)
      end
    end

    context "if the bookmark no longer exists" do
      it "raises an invalid access error" do
        expect { subject.destroy(9999) }.to raise_error(Discourse::NotFound)
      end
    end

    context "if the bookmark is scheduled with a reminder in sidekiq" do
      before do
        # this returns an array of Sidekiq::SortedEntry normally
        Jobs.stubs(:scheduled_for).returns([true])
      end
      it "cancells the reminder job" do
        Jobs.expects(:cancel_scheduled_job).with(:bookmark_reminder, bookmark_id: bookmark.id)
        subject.destroy(bookmark.id)
      end
    end
  end

  describe ".destroy_for_topic" do
    let!(:topic) { Fabricate(:topic) }
    let(:bookmark1) { Fabricate(:bookmark, topic: topic, post: Fabricate(:post, topic: topic), user: user) }
    let(:bookmark2) { Fabricate(:bookmark, topic: topic, post: Fabricate(:post, topic: topic), user: user) }

    it "destroys all bookmarks for the topic for the specified user" do
      subject.destroy_for_topic(topic)
      expect(Bookmark.where(user: user, topic: topic).length).to eq(0)
    end

    it "does not destroy any other user's topic bookmarks" do
      user2 = Fabricate(:user)
      Fabricate(:bookmark, topic: topic, post: Fabricate(:post, topic: topic), user: user2)
      subject.destroy_for_topic(topic)
      expect(Bookmark.where(user: user2, topic: topic).length).to eq(1)
    end
  end
end