require 'sinatra'
require 'sinatra/reloader' if development?
require 'haml'
require 'nokogiri'
require 'net/http'
require 'uri'
require 'cgi'
require 'models/story.rb'
require 'models/owner_work.rb'
require 'lib/helper.rb'
require 'date' #this is mac-specific, which doesn't require the standard libs.

before do
   @days_ago = params[:days_ago].to_i 
   @days_ago = 7 if @days_ago < 1
   @start_date = Date.today-@days_ago
   @pt_uri = URI.parse('http://www.pivotaltracker.com/')
end

get '/:projects/:api_key' do
    @title = 'Accepted Stories Report'
    @stories = Hash.new
    @labels = Hash.new
    @story_points = 0
    @owner_work = Hash.new
    
    #this simply assumes all stories are weighted the same, but if a story has multiple labels, it
    #splits it's weight across them.
    @label_weights = Hash.new(0)
    @created_stories = 0

    #which stories are still to come
    @upcoming_stories = Array.new
    @upcoming_story_counts = Hash.new(0)

    params[:projects].split(',').uniq.each do |project|

      doc = Nokogiri::HTML(stories(project, params[:api_key], "state:accepted%20includedone:true%20modified_since:#{@start_date.strftime("%m/%d/%Y")}"))
 
      doc.xpath('//story').each do |s| 
        sid = s.xpath('id')[0].content
        @stories[sid] = Story.new.from_xml(s)
        @story_points += @stories[sid].estimate
        @owner_work[@stories[sid].owned_by] ||= OwnerWork.new(@stories[sid].owned_by) and @owner_work[@stories[sid].owned_by].increment(@stories[sid].estimate)
      end
      
      
      begin
        @created_stories += Story.count_stories_from_xml(Nokogiri::HTML(created_since(@start_date, project, params[:api_key])))
        @improved = (@created_stories < @stories.count)
      rescue
      end
      
      #figure out which stories we expect to come this week
      begin
        doc = Nokogiri::HTML(this_week(project, params[:api_key]))
        doc.xpath('//stories//story').each do |s|
          story = Story.new.from_xml(s)
          if story.accepted_at.nil?
            @upcoming_stories << story
            @upcoming_story_counts[story.current_state] += 1
          end
        end
      end
    end

    @top_labels = Story.top_labels(@stories.values)
    @top_owners = @owner_work.values.sort{|a,b| 
      comp = (b.points_count <=> a.points_count )
      comp.zero? ? (b.story_count <=> a.story_count ) : comp 
    }
    
    haml :index
end

get '/status/:projects/:api_key' do

  include_icebox = (params[:icebox] != 'false')
  include_done = (params[:done] != 'false')
  include_backlog = (params[:backlog] != 'false')

  @done_stories = Array.new
  @done_points = 0

  @current_stories = Array.new
  @current_points = 0
  @next_up_stories = Array.new
  @next_points = 0
  @recently_delivered_by_owner = Hash.new

  @recently_logged_stories = Array.new
  @backlog_stories = Array.new
  @icebox = Array.new

  params[:projects].split(',').uniq.each do |project|

    #Work done in last iteration
    if(include_done)
       doc = Nokogiri::HTML(done(project, params[:api_key])) 
       story_iteration_iterator(doc) do |story|
        if story.accepted_at.nil?
          @recently_delivered_by_owner[story.owned_by] ||= Array.new and @recently_delivered_by_owner[story.owned_by] << story
        else
          @done_stories << story
          @done_points += story.estimate  
        end
      end
    end

    #Get the upcoming work
    begin
      doc = Nokogiri::HTML(this_week(project, params[:api_key]))
      story_iteration_iterator(doc) do |story|
        if story.current_state == 'unstarted'
          @next_up_stories << story
          @next_points += story.estimate
        else
          @current_stories << story
          @current_points += story.estimate
        end
      end
    end
    
    #Grab the recently logged stories
    begin
      doc = Nokogiri::HTML(created_since(@start_date, project, params[:api_key], 'state:unscheduled'))
      doc.xpath('//stories//story').each do |s|
        @recently_logged_stories << Story.new.from_xml(s)
      end
    end

    #Grab the rest of the backlog
    if include_backlog
      @backlog_stories = parse_stories_from_iterations(iterations(project, params[:api_key], 3, 1))
    end

    #Grab the icebox
    if(include_icebox)
      doc = Nokogiri::HTML(icebox(project, params[:api_key]))
      doc.xpath('//stories//story').take(20).each do |s|
        @icebox << Story.new.from_xml(s)
      end
    end
  end

  haml :status
end
