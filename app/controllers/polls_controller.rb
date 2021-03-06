class PollsController < ApplicationController
  helper :polls
  before_filter :login_required
  access_control [:new,  :edit, :create, :update, :destroy,
    :publish, :unpublish ] => 'prodmgr'

  # GETs should be safe (see http://www.w3.org/2001/tag/doc/whenToUseGet.html)
  verify :method => :post, :only => [:create, :publish, :unpublish, :take_survey ],
    :redirect_to => { :action => :index }
  verify :method => :put, :only => [ :update ],
    :redirect_to => { :action => :index }
  verify :method => :delete, :only => [ :destroy ],
    :redirect_to => { :action => :index }
  
  def index
    new
    @polls = Poll.list params[:page], prodmgr?, current_user.row_limit, current_user
  end

  def show
    session[:polls_show_toggle_detail] ||= "HIDE"
    
    @poll = Poll.find(params[:id])
    @graph = open_flash_chart_object(450,450, pie_poll_url(@poll))     
  end

  def pie
    poll = Poll.find(params[:id])
    
    #    total_responses = poll.poll_options.collect(&:user_responses).size
    pie_values = []
    for option in poll.poll_options
      if option.user_responses.size > 0
        pie_values << PieValue.new(option.user_responses.size, "#{StringUtils.truncate option.description, 16}")
      end
    end

    pie_chart = Pie.new
    pie_chart.start_angle = 35
    pie_chart.animate = true
    pie_chart.tooltip = '#val# of #total#<br>#percent#'
    pie_chart.values  = pie_values
    pie_chart.colours = %w(#CF2626 #5767AF  #D01FC3 #356AA0 #CF5ACD #CF750C #FF7200 #8F1A1A #ADD700 #57AF9D #C3CF5A #456F4F #C79810)
    
    chart = OpenFlashChart.new
    
    chart.bg_colour = '#ffffcc'
    chart.title = Title.new("Survey Responses")
    chart.add_element(pie_chart)
    chart.x_axis = nil
    render :text => chart.to_s
  end


  def new
    @poll = Poll.new
    @poll.close_date = Date.jd(DateUtils.today_utc.jd + 7)
  end

  def create
    params[:poll][:group_ids] ||= []
    params[:poll][:enterprise_type_ids] ||= []
    @poll = Poll.new(params[:poll])
    @poll.poll_options << PollOption.new(:description => 'Choice 1...')
    @poll.poll_options << PollOption.new(:description => 'Choice 2...')
    if @poll.save
      flash[:notice] = "Poll #{@poll.title} was successfully created."
      redirect_to edit_poll_path(@poll)
    else
      index
      render :action => :index
    end
  end

  def edit
    @poll = Poll.find(params[:id])
  end

  def update
    params[:poll][:group_ids] ||= []
    params[:poll][:enterprise_type_ids] ||= []
    @poll = Poll.find(params[:id])
    if @poll.update_attributes(params[:poll])
      flash[:notice] = "Poll '#{@poll.title}' was successfully updated."
      redirect_to poll_path(@poll)
    else
      render :action => :edit
    end
  end

  def destroy
    poll = Poll.find(params[:id])
    title = poll.title
    poll.destroy
    flash[:notice] = "Poll #{title} was successfully deleted."
    redirect_to polls_url
  end
  
  def publish
    poll = set_active params[:id], true
    flash[:notice] = "Poll #{poll.title} was successfully published."
    redirect_to polls_url
  end
  
  def unpublish
    poll = set_active params[:id], false
    flash[:notice] = "Poll #{poll.title} was successfully unpublished."
    redirect_to polls_url
  end
  
  def self.POLL_NO_THANKS_ACTION
    "No Thanks"
  end
  
  def take_survey
    if (params[:action] == PollsController.POLL_NO_THANKS_ACTION)
      poll = Poll.find(params[:id])
      poll.user_responses << poll.unselectable_poll_option
      poll.save
      redirect_to home_path
    else
      if params[:poll_option_id].nil?
        take_survey_failed "You must select an option"
      else
        poll_option = PollOption.find(params[:poll_option_id])
        if poll_option.poll.taken_survey?(current_user)
          take_survey_failed "You can only answer this survey once"
        else
          Poll.transaction do
            poll_option.user_responses << current_user
            unless params[:comment_body].blank?
              poll_option.poll.comments << PollComment.new(
                :user_id => current_user.id,
                :body => params[:comment_body])
              poll_option.poll.save
            end
            poll_option.save
          end
          redirect_to poll_path(poll_option.poll)
        end
      end
    end
  end
  
  #  def self.POLL_OPTION_ANSWER_SURVEY 
  #    "Answer Survey"
  #  end
  #  
  #  def self.POLL_OPTION_ASK_ME_LATER
  #    "Not Now"
  #  end
  #  
  #  def self.POLL_OPTION_NEVER
  #    "Never"
  #  end
  
  def present_survey
    @poll = Poll.find(params[:id])
    if @poll.taken_survey?(current_user)
      flash[:error] = "You can only answer this survey once"
      redirect_to poll_path(@poll)
    end
  end
  
  def toggle_details
    poll = Poll.find(params[:id])
    if session[:polls_show_toggle_detail] == "HIDE"
      session[:polls_show_toggle_detail] = "SHOW"
    else
      session[:polls_show_toggle_detail] = "HIDE"
    end
    
    respond_to do |format|
      format.html { 
        show
        render poll_path(poll)
      }
      format.js  { do_rjs_toggle_details poll }
    end
  end
  
  def display_comments
    poll = Poll.find(params[:id])
    
    respond_to do |format|
      format.html { 
        present_survey
        render present_survey_poll_path(poll)
      }
      format.js  { do_rjs_display_comments poll }
    end
  end
  
  private
  
  def take_survey_failed(msg)
    @poll = Poll.find(params[:id])
    flash[:error] = msg
    render :action => :present_survey
  end
  
  def set_active(id, active)
    @poll = Poll.find(id)
    @poll.active = active
    @poll.save
    @poll
  end
  
  def do_rjs_toggle_details  poll
    render :update do |page|
      if session[:polls_show_toggle_detail] == "HIDE"
        page.visual_effect :blind_up, "hide_images", :duration => 0.2
        page.visual_effect :blind_down, "show_images", :duration => 1
        page.visual_effect :blind_up, "show_comments", :duration => 1
        for option in poll.poll_options
          page.visual_effect :squish, "details#{option.id}", :duration => 0.5
        end
      else
        page.visual_effect :blind_up, "show_images", :duration => 0.2
        page.visual_effect :blind_down, "hide_images", :duration => 1
        page.visual_effect :blind_down, "show_comments", :duration => 1
        for option in poll.poll_options
          page.visual_effect :blind_down, "details#{option.id}", :duration => 1
        end
      end
    end
  end
  
  def do_rjs_display_comments  poll
    render :update do |page|
      page.visual_effect :blind_up, "show_comment_button", :duration => 0.2
      page.visual_effect :blind_down, "addcomment", :duration => 1
    end
  end
end