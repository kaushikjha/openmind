require 'digest/sha1'

class User < ActiveRecord::Base
  # Virtual attribute for the unencrypted password
  attr_accessor :password
  attr_protected :activated_at 

  validates_presence_of     :email, :row_limit, :last_name, :enterprise
  validates_presence_of     :password,                   :if => :password_required?
  validates_presence_of     :password_confirmation,      :if => :password_required?
  validates_length_of       :password, :within => 4..40, :if => :password_required?
  validates_confirmation_of :password,                   :if => :password_required?
  validates_length_of       :email,    :within => 3..100
  validates_uniqueness_of   :email, :case_sensitive => false
  validates_email_format_of :email
  validates_numericality_of :row_limit 
  before_save :encrypt_password
  
  belongs_to :enterprise
  has_and_belongs_to_many :roles  
  # This collection is for watches
  has_and_belongs_to_many :watched_ideas, :join_table => 'watches', :class_name => 'Idea'
  has_and_belongs_to_many :forum_watches, :join_table => 'forum_watches', :class_name => 'Forum'
  has_many :topic_watches
  # couldn't get through to work
  has_many :watched_topics, :class_name => 'Topic',
    :finder_sql => 'SELECT t.* ' +
    'from Topics AS t ' +
    'INNER JOIN topic_watches AS tw ON t.id = tw.topic_id ' +
    'WHERE tw.user_id = #{id} ' +
    'ORDER BY t.forum_id, t.updated_at DESC'
  has_and_belongs_to_many :poll_options, :join_table => 'poll_user_responses'
  has_and_belongs_to_many :mediated_forums, :join_table => 'forum_mediators', :class_name => 'Forum'
  
  has_one :last_logon, :class_name => "UserLogon", :order => "created_at DESC"
  has_many :user_logons, :order => "created_at DESC", :dependent => :destroy   
  has_many :ideas,:dependent => :destroy    
  has_many :allocations,:dependent => :destroy    
  # all votes by this user based only on user allocations
  has_many :votes, :through => :allocations
  # all votes by this user regardless of allocation
  has_many :all_votes, :class_name => 'Vote', :foreign_key => "user_id"
  has_many :comments,:dependent => :destroy    
  has_many :user_idea_reads,:dependent => :destroy
  
  before_create :make_activation_code

  def self.row_limit_options
    [10, 25, 50, 100]
  end
  
  def user_logons_90_days
    user_logons.find(:all, :conditions => ['created_at > ?', (Time.now - 60*60*24*90).to_s(:db)])
  end
  
  def active_allocations
    allocations.find(:all, 
      :conditions => ['expiration_date >= ?', (Date.today).to_s(:db)],
      :order => 'expiration_date asc')
  end
  
  # imported users have both activated_at and activation_code as null
  def self.imported_users
    User.find(:all, :conditions => ["activated_at is null and activation_code is null" ])
  end
  
  def last_logon_date
    last_logon.created_at unless last_logon.nil?
  end
  
  # Authenticates a user by their email and unencrypted password.  Returns the user or nil.
  def self.authenticate(email, password)
    # hide records with a nil activated_at
    u = User.find :first, :conditions => ['email = ? and activated_at IS NOT NULL', email]
    u && u.authenticated?(password) ? u : nil
  end

  # Encrypts some data with the salt.
  def self.encrypt(password, salt)
    Digest::SHA1.hexdigest("--#{salt}--#{password}--")
  end

  # Encrypts the password with the user salt
  def encrypt(password)
    self.class.encrypt(password, salt)
  end

  def authenticated?(password)
    crypted_password == encrypt(password) && enterprise.active && active && 
      !activated_at.nil?
  end

  def remember_token?
    remember_token_expires_at && Time.now.utc < remember_token_expires_at 
  end
  
  def login
    email
  end
  
  def login=(p_login)
    self.email = p_login
  end

  # These create and unset the fields required for remembering users between browser closes
  def remember_me
    self.remember_token_expires_at = 2.weeks.from_now.utc
    self.remember_token            = encrypt("#{email}--#{remember_token_expires_at}")
    save(false)
  end

  def forget_me
    self.remember_token_expires_at = nil
    self.remember_token            = nil
    save(false)
  end
  
  def can_delete?
    ideas.empty? and allocations.empty? and comments.empty?
  end
  
  def available_user_votes
    user_allocations = active_allocations.collect(&:quantity).sum
    user_allocations = 0 if active_allocations.nil?
    
    user_allocations - votes.size
  end
  
  def available_enterprise_votes
    enterprise_allocations = enterprise.active_allocations.collect(&:quantity).sum
    enterprise_allocations = 0 if enterprise_allocations.nil?
    
    enterprise_allocations - enterprise.votes.size
  end
  
  def available_votes
    available_user_votes + available_enterprise_votes
  end
    
  def self.list(page, per_page)
    paginate :page => page, :order => 'email', 
      :per_page => per_page, :include => 'enterprise'
  end
  
  def self.active_users
    User.find_all_by_active(true, :order => 'email')
  end
  
  def self.active_voters
    User.find_all_by_active(true, 
      :joins => "inner join roles_users as ru on users.id = ru.user_id inner join roles as r on ru.role_id = r.id", 
      :conditions => "r.title = 'Voter'", 
      :select => 'users.*',
      :order => 'email')
  end
  
  def user_time(time)
    tz = TimeZone[time_zone]
    time = tz.adjust time unless tz.nil?
    time
  end
  
  def full_name
    full_name = ""
    if !self.first_name.nil?
      full_name << self.first_name
      full_name << " "
    end
    full_name << self.last_name
    full_name
  end
  
  def short_name
    return self.last_name if self.first_name.nil? or self.first_name.length == 0
    "#{self.first_name} #{self.last_name[0, 1]}"
  end
  
  def new_random_password
    self.salt = Digest::SHA1.hexdigest("--#{Time.now.to_s}--#{email}--")
    self.password=  self.salt[0,6]
    self.password_confirmation = self.password
  end
  
  # Activates the user in the database.
  def activate
    @activated = true
    self.activated_at = Time.now
    self.activation_code = nil
    self.save!
  end

  # Returns true if the user has just been activated.
  def recently_activated?
    @activated
  end
  
  def display_name always_full=false
    return "#{self.short_name}" if self.hide_contact_info and !always_full
    "#{self.full_name} (#{self.email})"
  end
  
  def reset_password
    new_random_password
    self.activated_at = nil
    make_activation_code
    self.force_change_password = true
  end
  
  def unread_announcements?
    last_announcement = Announcement.find(:first, :order => "created_at DESC")
    return false if last_announcement.nil?
    return true if self.last_message_read.nil?
    self.last_message_read < last_announcement.created_at
  end
  
  def open_polls
    Poll.open_polls(self)
  end
  
  def watch_topic(topic)
    topic_watches.create(:topic => topic)
  end

  protected
  # before filter 
  def encrypt_password
    return if password.blank?
    self.salt = Digest::SHA1.hexdigest("--#{Time.now.to_s}--#{email}--") if new_record?
    self.crypted_password = encrypt(password)
  end
    
  def password_required?
    crypted_password.blank? || !password.blank?
  end

  def validate
    errors.add(:row_limit, "should be at least 1 or greater") if row_limit.nil?  || row_limit < 1
  end

  def make_activation_code
    # special keyword SKIP will prevent the activation code from being created
    if self.activation_code == 'SKIP'
      self.activation_code = nil
    else
      self.activation_code = Digest::SHA1.hexdigest( Time.now.to_s.split(//).sort_by {rand}.join ) 
    end
  end
end