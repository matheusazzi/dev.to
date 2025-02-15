require "rails_helper"

RSpec.describe Comment, type: :model do
  let_it_be(:user) { create(:user) }
  let_it_be(:article) { create(:article, user: user) }
  let_it_be(:comment) { create(:comment, user: user, commentable: article) }

  include_examples "#sync_reactions_count", :article_comment

  describe "validations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:commentable) }
    it { is_expected.to have_many(:reactions).dependent(:destroy) }
    it { is_expected.to have_many(:mentions).dependent(:destroy) }
    it { is_expected.to have_many(:notifications).dependent(:delete_all) }
    it { is_expected.to have_many(:notification_subscriptions).dependent(:destroy) }
    it { is_expected.to validate_presence_of(:commentable_id) }
    it { is_expected.to validate_presence_of(:body_markdown) }

    it do
      # rubocop:disable RSpec/NamedSubject
      subject.commentable = article
      subject.user = user
      expect(subject).to(
        validate_uniqueness_of(:body_markdown).scoped_to(:user_id, :ancestry, :commentable_id, :commentable_type),
      )
      # rubocop:enable RSpec/NamedSubject
    end

    it { is_expected.to validate_length_of(:body_markdown).is_at_least(1).is_at_most(25_000) }
    it { is_expected.to validate_inclusion_of(:commentable_type).in_array(%w[Article PodcastEpisode]) }

    it "is invalid if commentable is unpublished article" do
      # rubocop:disable RSpec/NamedSubject
      subject.commentable = build(:article, published: false)
      expect(subject).not_to be_valid
      # rubocop:enable RSpec/NamedSubject
    end

    describe "#processed_html" do
      let(:comment) { build(:comment, user: user, commentable: article) }

      it "converts body_markdown to proper processed_html" do
        comment.body_markdown = "# hello\n\nhy hey hey"
        comment.validate!
        expect(comment.processed_html.include?("<h1>")).to be(true)
      end

      it "adds rel=nofollow to links" do
        comment.body_markdown = "this is a comment with a link: http://dev.to"
        comment.validate!
        expect(comment.processed_html.include?('rel="nofollow"')).to be(true)
      end

      it "adds a mention url if user is mentioned like @mention" do
        comment.body_markdown = "Hello @#{user.username}, you are cool."
        comment.validate!
        expect(comment.processed_html.include?("/#{user.username}")).to be(true)
        expect(comment.processed_html.include?("href")).to be(true)
        expect(comment.processed_html.include?("Hello <a")).to be(true)
      end

      it "not double wrap an already-linked mention" do
        comment.body_markdown = "Hello <a href='/#{user.username}'>@#{user.username}</a>, you are cool."
        comment.validate!
        expect(comment.processed_html.scan(/href/).count).to eq(1)
      end

      it "does not wrap email mention with username" do
        comment.body_markdown = "Hello hello@#{user.username}.com, you are cool."
        comment.validate!
        expect(comment.processed_html.include?("/#{user.username}")).to be(false)
      end

      it "only mentions users who are actual users" do
        comment.body_markdown = "Hello @hooper, you are cool."
        comment.validate!
        expect(comment.processed_html.include?("/hooper")).to be(false)
      end

      it "mentions people if it is the first word" do
        comment.body_markdown = "@#{user.username}, you are cool."
        comment.validate!
        expect(comment.processed_html.include?("/#{user.username}")).to be(true)
      end

      it "does case insentive mention recognition" do
        comment.body_markdown = "Hello @#{user.username.titleize}, you are cool."
        comment.validate!
        expect(comment.processed_html.include?("/#{user.username}")).to be(true)
        expect(comment.processed_html.include?("href")).to be(true)
        expect(comment.processed_html.include?("Hello <a")).to be(true)
      end

      it "shortens long urls" do
        comment.body_markdown = "Hello https://longurl.com/#{'x' * 100}?#{'y' * 100}"
        comment.validate!
        expect(comment.processed_html.include?("...</a>")).to be(true)
        expect(comment.processed_html.size < 450).to be(true)
      end

      it "adds timestamp url if commentable has video and timestamp", :aggregate_failures do
        article.video = "https://example.com"

        comment.body_markdown = "I like the part at 4:30"
        comment.validate!
        expect(comment.processed_html.include?(">4:30</a>")).to be(true)

        comment.body_markdown = "I like the part at 4:30 and 5:50"
        comment.validate!
        expect(comment.processed_html.include?(">5:50</a>")).to eq(true)

        comment.body_markdown = "I like the part at 5:30 and :55"
        comment.validate!
        expect(comment.processed_html.include?(">:55</a>")).to eq(true)

        comment.body_markdown = "I like the part at 52:30"
        comment.validate!
        expect(comment.processed_html.include?(">52:30</a>")).to eq(true)

        comment.body_markdown = "I like the part at 1:52:30 and 1:20"
        comment.validate!
        expect(comment.processed_html.include?(">1:52:30</a>")).to eq(true)
        expect(comment.processed_html.include?(">1:20</a>")).to eq(true)
      end

      it "does not add timestamp if commentable does not have video" do
        article.video = nil

        comment.body_markdown = "I like the part at 1:52:30 and 1:20"
        comment.validate!
        expect(comment.processed_html.include?(">1:52:30</a>")).to eq(false)
      end
    end
  end

  describe "#id_code_generated" do
    it "gets proper generated ID code" do
      expect(described_class.new(id: 1000).id_code_generated).to eq("1cc")
    end
  end

  describe "#readable_publish_date" do
    it "does not show year in readable time if not current year" do
      expect(comment.readable_publish_date).to eq(comment.created_at.strftime("%b %e"))
    end

    it "shows year in readable time if not current year" do
      comment.created_at = 1.year.ago
      last_year = 1.year.ago.year % 100
      expect(comment.readable_publish_date.include?("'#{last_year}")).to eq(true)
    end
  end

  describe "#path" do
    it "returns the properly formed path" do
      expect(comment.path).to eq("/#{comment.user.username}/comment/#{comment.id_code_generated}")
    end
  end

  describe "#parent_or_root_article" do
    it "returns root article if no parent comment" do
      expect(comment.parent_or_root_article).to eq(comment.commentable)
    end

    it "returns root parent comment if exists" do
      child_comment = build(:comment, parent: comment)
      expect(child_comment.parent_or_root_article).to eq(comment)
    end
  end

  describe "#parent_user" do
    it "returns the root article's user if no parent comment" do
      expect(comment.parent_user).to eq(user)
    end

    it "returns the root parent comment's user if root parent comment exists" do
      child_comment_user = build(:user)
      child_comment = build(:comment, parent: comment, user: child_comment_user)
      expect(child_comment.parent_user).not_to eq(child_comment_user)
      expect(child_comment.parent_user).to eq(comment.user)
    end
  end

  describe "#title" do
    it "is no more than 80 characters" do
      expect(comment.title.length).to be <= 80
    end

    it "is allows title of greater length if passed" do
      expect(comment.title(5).length).to eq(5)
    end

    it "retains content from #processed_html" do
      comment.processed_html = "Hello this is a post." # Remove randomness
      comment.validate!
      text = comment.title.gsub("...", "").delete("\n")
      expect(comment.processed_html).to include(CGI.unescapeHTML(text))
    end

    it "is converted to deleted if the comment is deleted" do

      comment.deleted = true
      expect(comment.title).to eq("[deleted]")
    end

    it "does not contain the wrong encoding" do
      comment.body_markdown = "It's the best post ever. It's so great."

      comment.validate!
      expect(comment.title).not_to include("&#39;")
    end
  end

  describe "#index_id" do
    it "is equal to comments-ID" do
      # NOTE: we shouldn't test private things but cheating a bit for Algolia here
      expect(comment.send(:index_id)).to eq("comments-#{comment.id}")
    end
  end

  describe "#custom_css" do
    it "returns nothing when no liquid tag was used" do
      expect(comment.custom_css).to be_blank
    end

    it "returns proper liquid tag classes if used" do
      text = "{% devcomment #{comment.id_code_generated} %}"
      comment.body_markdown = text
      expect(comment.custom_css).to be_present
    end
  end

  describe ".tree_for" do
    let_it_be(:other_comment) { create(:comment, commentable: article, user: user) }
    let_it_be(:child_comment) { create(:comment, commentable: article, parent: comment, user: user) }

    before { comment.update_column(:score, 1) }

    it "returns a full tree" do
      comments = described_class.tree_for(article)
      expect(comments).to eq(comment => { child_comment => {} }, other_comment => {})
    end

    it "returns part of the tree" do
      comments = described_class.tree_for(article, 1)
      expect(comments).to eq(comment => { child_comment => {} })
    end
  end

  context "when callbacks are triggered before save" do
    it "generates character count before saving" do
      comment.save
      expect(comment.markdown_character_count).to eq(comment.body_markdown.size)
    end
  end

  context "when callbacks are triggered after save" do
    it "updates user last comment date" do
      expect { comment.save }.to change(user, :last_comment_at)
    end
  end

  context "when callbacks are triggered after update" do
    it "deletes the comment's notifications when deleted is set to true" do
      create(:notification, notifiable: comment, user: user)
      perform_enqueued_jobs do
        comment.update(deleted: true)
      end
      expect(comment.notifications).to be_empty
    end

    it "updates the notifications of the descendants with [deleted]" do
      comment = create(:comment, commentable: article)
      child_comment = create(:comment, parent: comment, commentable: article, user: user)
      create(:notification, notifiable: child_comment, user: user)
      perform_enqueued_jobs do
        comment.update(deleted: true)
      end
      notification = child_comment.notifications.first
      expect(notification.json_data["comment"]["ancestors"][0]["title"]).to eq("[deleted]")
    end
  end

  context "when callbacks are triggered after destroy" do
    it "updates user's last_comment_at" do
      expect { comment.destroy }.to change(user, :last_comment_at)
    end
  end

  describe "when indexing and deindexing" do
    let!(:comment) { create(:comment, commentable: article) }

    context "when destroying" do
      it "doesn't trigger auto removal from index" do
        expect { comment.destroy }.not_to have_enqueued_job.on_queue("algoliasearch")
      end
    end

    context "when deleted is false" do
      it "checks auto-indexing" do
        expect do
          comment.update(body_markdown: "hello")
        end.to have_enqueued_job(Search::IndexJob).with("Comment", comment.id)
      end
    end

    context "when deleted is true" do
      it "checks auto-deindexing" do
        expect do
          comment.update(deleted: true)
        end.to have_enqueued_job(Search::RemoveFromIndexJob).with(described_class.algolia_index_name, comment.index_id)
      end
    end
  end
end
