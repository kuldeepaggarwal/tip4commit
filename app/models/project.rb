class Project < ActiveRecord::Base
  has_many :deposits # todo: only confirmed deposits that have amount > paid_out
  has_many :tips

  validates :full_name, :github_id, uniqueness: true, presence: true
  validates :host, inclusion: [ "github", "bitbucket" ], presence: true

  def update_repository_info repo
    self.github_id = repo.id
    self.name = repo.name
    self.full_name = repo.full_name
    self.source_full_name = repo.source.full_name rescue ''
    self.description = repo.description
    self.watchers_count = repo.watchers_count
    self.language = repo.language
    self.save!
  end

  def repository_client
    if host.present?
      host.classify.constantize.new
    end
  end

  def github_url
    repository_client.repository_url self
  end

  def source_github_url
    repository_client.source_repository_url self
  end

  def raw_commits
    repository_client.commits self
  end

  def repository_info
    repository_client.repository_info self
  end

  def new_commits
    begin
      commits = Timeout::timeout(90) do
        raw_commits.
          # Filter merge request
          select{|c| !(c.commit.message =~ /^(Merge\s|auto\smerge)/)}.
          # Filter fake emails
          select{|c| c.commit.author.email =~ Devise::email_regexp }.
          # Filter commited after t4c project creation
          select{|c| c.commit.committer.date > self.deposits.first.created_at }.
          to_a
      end
    rescue Octokit::BadGateway, Octokit::NotFound, Octokit::InternalServerError,
           Errno::ETIMEDOUT, Net::ReadTimeout, Faraday::Error::ConnectionFailed => e
      Rails.logger.info "Project ##{id}: #{e.class} happened"
    rescue StandardError => e
      Airbrake.notify(e)
    end
    sleep(1)
    commits || []
  end

  def tip_commits
    new_commits.each do |commit|
      Project.transaction do
        tip_for commit
        update_attribute :last_commit, commit.sha
      end
    end
  end

  def tip_for commit
    if (next_tip_amount > 0) && !Tip.exists?(commit: commit.sha)

      user = User.find_or_create_with_commit commit
      user.update(nickname: commit.author.login) if commit.author.try(:login)

      # create tip
      tip = tips.create({ user: user,
                          amount: next_tip_amount,
                          commit: commit.sha })

      # notify user
      notify_user_about_tip(user, tip)

      Rails.logger.info "    Tip created #{tip.inspect}"
    end
  end

  def available_amount
    self.deposits.where("confirmations > 0").map(&:available_amount).sum - tips_paid_amount
  end

  def unconfirmed_amount
    self.deposits.where(:confirmations => 0).where('created_at > ?', 7.days.ago).map(&:available_amount).sum
  end

  def tips_paid_amount
    self.tips.non_refunded.sum(:amount)
  end

  def tips_paid_unclaimed_amount
    self.tips.non_refunded.unclaimed.sum(:amount)
  end

  def next_tip_amount
    (CONFIG["tip"]*available_amount).ceil
  end

  def update_cache
    update available_amount_cache: available_amount
  end

  def self.update_cache
    find_each do |project|
      project.update_cache
    end
  end

  def update_info
    begin
      update_repository_info(repository_info)
    rescue Octokit::BadGateway, Octokit::NotFound, Octokit::InternalServerError,
           Errno::ETIMEDOUT, Net::ReadTimeout, Faraday::Error::ConnectionFailed => e
      Rails.logger.info "Project ##{id}: #{e.class} happened"
    rescue StandardError => e
      Airbrake.notify(e)
    end
  end

  def notify_user_about_tip user, tip
    if tip && user.bitcoin_address.blank? && user.subscribed?
      if !user.notified_at || (user.notified_at < (Time.current - 30.days))
        UserMailer.new_tip(user, tip).deliver
        user.touch :notified_at
      end
    end
  end
end
