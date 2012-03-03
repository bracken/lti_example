require 'sinatra'
require 'ims/lti'
require 'json'
require 'dm-core'
require 'dm-migrations'
require 'oauth/request_proxy/rack_request'

# hard-coded oauth information for testing convenience
$oauth_key = "test"
$oauth_secret = "secret"

# sinatra wants to set x-frame-options by default, disable it
disable :protection
# enable sessions so we can remember the launch info between http requests, as
# the user takes the assessment
enable :sessions

class ExternalConfig
  include DataMapper::Resource
  property :id, Serial
  property :config_type, String
  property :value, String
end

configure do
  DataMapper.setup(:default, (ENV["DATABASE_URL"] || "sqlite3:///#{Dir.pwd}/development.sqlite3"))
  DataMapper.auto_upgrade!
  @@quizlet_config = ExternalConfig.first(:config_type => 'quizlet')
end

# this is the entry action that Canvas (the LTI Tool Consumer) sends the
# browser to when launching the tool.
post "/assessment/start" do
  # create a ToolProvider object to verify the request
  @tool_provider = IMS::LTI::ToolProvider.new($oauth_key, $oauth_secret, params)
  
  # first we have to verify the oauth signature, to make sure this isn't an
  # attempt to hack the planet
  if !@tool_provider.valid_request?(request)
    return %{unauthorized attempt. make sure you used the consumer secret "#{$oauth_secret}"}
  end

  # make sure this is an assignment tool launch, not another type of launch.
  # only assignment tools support the outcome service, since only they appear
  # in the Canvas gradebook.
  unless @tool_provider.outcome_service?
    return %{It looks like this LTI tool wasn't launched as an assignment, or you are trying to take it as a teacher rather than as a a student. Make sure to set up an external tool assignment as outlined <a target="_blank" href="https://github.com/instructure/lti_example">in the README</a> for this example.}
  end

  # store the relevant parameters from the launch into the user's session, for
  # access during subsequent http requests.
  # note that the name and email might be blank, if the tool wasn't configured
  # in Canvas to provide that private information.
  session['launch_params'] = @tool_provider.to_params

  # that's it, setup is done. now send them to the assessment!
  redirect to("/assessment")
end

get "/assessment" do
  @tool_provider = IMS::LTI::ToolProvider.new($oauth_key, $oauth_secret, session['launch_params'])
  # first make sure they got here through a tool launch
  unless @tool_provider.outcome_service?
    return %{You need to take this assessment through Canvas.}
  end
  @username = @tool_provider.username || "Dude"
  
  # now render a simple form the user will submit to "take the quiz"
  erb :assessment
end

# This is the action that the form submits to with the score that the student entered.
# In lieu of a real assessment, that score is then just submitted back to Canvas.
post "/assessment" do
  @tool_provider = IMS::LTI::ToolProvider.new($oauth_key, $oauth_secret, session['launch_params'])
  
  # obviously in a real tool, we're not going to let the user input their own score
  score = params['score']
  if !score || score.empty?
    redirect to("/assessment")
  end
  
  response = @tool_provider.post_outcome(score)

  headers 'Content-Type' => 'text'
  <<-TEXT
  Your score has #{@tool_provider.outcome_post_successful? ? "been posted" : "failed in posting"} to Canvas. The response was:
  Response code: #{response.code}
  #{response.body}
  TEXT
end

get "/" do
  erb :index
end

get "/quizlet_search" do
  return "Quizlet not propertly configured" unless @@quizlet_config
  uri = URI.parse("https://api.quizlet.com/2.0/search/sets")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  tmp_url = uri.path+"?q=#{params['q']}&client_id=#{@@quizlet_config.value}"
  request = Net::HTTP::Get.new(tmp_url)
  response = http.request(request)
  return response.body
end

def config_wrap(xml)
  res = <<-XML
<?xml version="1.0" encoding="UTF-8"?>
  <cartridge_basiclti_link xmlns="http://www.imsglobal.org/xsd/imslticc_v1p0"
      xmlns:blti = "http://www.imsglobal.org/xsd/imsbasiclti_v1p0"
      xmlns:lticm ="http://www.imsglobal.org/xsd/imslticm_v1p0"
      xmlns:lticp ="http://www.imsglobal.org/xsd/imslticp_v1p0"
      xmlns:xsi = "http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation = "http://www.imsglobal.org/xsd/imslticc_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imslticc_v1p0.xsd
      http://www.imsglobal.org/xsd/imsbasiclti_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imsbasiclti_v1p0.xsd
      http://www.imsglobal.org/xsd/imslticm_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imslticm_v1p0.xsd
      http://www.imsglobal.org/xsd/imslticp_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imslticp_v1p0.xsd">
  XML
  res += xml
  res += <<-XML
      <cartridge_bundle identifierref="BLTI001_Bundle"/>
      <cartridge_icon identifierref="BLTI001_Icon"/>
  </cartridge_basiclti_link>  
  XML
end

get "/config/course_navigation.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>Course Wanda Fish</blti:title>
    <blti:description>This tool adds a course navigation link to a page on a fish called "Wanda"</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="course_navigation">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/images.html?custom_fish_name=wanda')}</lticm:property>
        <lticm:property name="text">Course Wanda Fish</lticm:property>
      </lticm:options>
    </blti:extensions>
  XML
end

get "/config/account_navigation.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>Account Phil Fish</blti:title>
    <blti:description>This tool adds an account navigation link to a page on a fish named "Phil"</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="account_navigation">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/images.html?custom_fish_name=phil')}</lticm:property>
        <lticm:property name="text">Account Phil Fish</lticm:property>
      </lticm:options>
    </blti:extensions>
  XML
end

get "/config/user_navigation.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>User Alexander Fish</blti:title>
    <blti:description>This tool adds a user navigation link (in a user's profile) to a page on a fish called "Alexander"</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="user_navigation">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/images.html?custom_fish_name=alexander')}</lticm:property>
        <lticm:property name="text">User Alexander Fish</lticm:property>
      </lticm:options>
    </blti:extensions>
    <blti:icon>#{host}/fish_icon.png</blti:icon>
  XML
end

get "/config/grade_passback.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>Grade Passback Demo</blti:title>
    <blti:description>This tool demos the LTI Outcomes (grade passback) available as part of LTI</blti:description>
    <blti:launch_url>#{host}/assessment/start</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
    </blti:extensions>
  XML
end

get "/config/editor_button.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>I Like Fish</blti:title>
    <blti:description>I'm a big fan of fish, and I want to share the love</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="editor_button">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/images.html')}</lticm:property>
        <lticm:property name="icon_url">#{host}/fish_icon.png</lticm:property>
        <lticm:property name="text">Pick a Fish</lticm:property>
        <lticm:property name="selection_width">500</lticm:property>
        <lticm:property name="selection_height">300</lticm:property>
      </lticm:options>
    </blti:extensions>
    <blti:icon>#{host}/fish_icon.png</blti:icon>
  XML
end

get "/config/editor_button2.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>Placekitten.com</blti:title>
    <blti:description>Placekitten.com is a quick and simple service for adding pictures of kittens to your site</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="editor_button">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/kitten.html')}</lticm:property>
        <lticm:property name="icon_url">#{host}/cat_icon.png</lticm:property>
        <lticm:property name="text">Insert a Kitten</lticm:property>
        <lticm:property name="selection_width">500</lticm:property>
        <lticm:property name="selection_height">400</lticm:property>
      </lticm:options>
    </blti:extensions>
    <blti:icon>#{host}/cat_icon.png</blti:icon>
  XML
end

get "/config/resource_selection.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>I Like Fish</blti:title>
    <blti:description>I'm a big fan of fish, and I want to share the love</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="resource_selection">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/name.html')}</lticm:property>
        <lticm:property name="text">Pick a Fish Name</lticm:property>
        <lticm:property name="selection_width">500</lticm:property>
        <lticm:property name="selection_height">300</lticm:property>
      </lticm:options>
    </blti:extensions>
  XML
end

get "/config/editor_button_and_resource_selection.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>I Like Fish</blti:title>
    <blti:description>I'm a big fan of fish, and I want to share the love</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="editor_button">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/images.html')}</lticm:property>
        <lticm:property name="icon_url">#{host}/fish_icon.png</lticm:property>
        <lticm:property name="text">Pick a Fish</lticm:property>
        <lticm:property name="selection_width">500</lticm:property>
        <lticm:property name="selection_height">300</lticm:property>
      </lticm:options>
      <lticm:options name="resource_selection">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/name.html')}</lticm:property>
        <lticm:property name="text">Pick a Fish Name</lticm:property>
        <lticm:property name="selection_width">500</lticm:property>
        <lticm:property name="selection_height">300</lticm:property>
      </lticm:options>
    </blti:extensions>
  XML
end

get "/config/inline_graph.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>Embeddable Graphs</blti:title>
    <blti:description>This tool allows for the creation and insertion of rich, interactive graphs.</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="editor_button">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/graph.html')}</lticm:property>
        <lticm:property name="icon_url">#{host}/graph.tk/favicon.ico</lticm:property>
        <lticm:property name="text">Embed Graph</lticm:property>
        <lticm:property name="selection_width">740</lticm:property>
        <lticm:property name="selection_height">450</lticm:property>
      </lticm:options>
    </blti:extensions>
    <blti:icon>#{host}/graph.tk/favicon.ico</blti:icon>
  XML
end

get "/config/khan_academy.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>Khan Academy Videos</blti:title>
    <blti:description>Search for and insert links to Khan Academy lecture videos.</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="editor_button">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/khan.html')}</lticm:property>
        <lticm:property name="icon_url">#{host}/khan.ico</lticm:property>
        <lticm:property name="text">Find Khan Academy Video</lticm:property>
        <lticm:property name="selection_width">590</lticm:property>
        <lticm:property name="selection_height">450</lticm:property>
      </lticm:options>
    </blti:extensions>
    <blti:icon>#{host}/khan.ico</blti:icon>
  XML
end

get "/config/quizlet.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>Quizlet Flash Cards</blti:title>
    <blti:description>Search for and insert publicly available flash card sets from quizlet.com</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="editor_button">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/quizlet.html')}</lticm:property>
        <lticm:property name="icon_url">#{host}/quizlet.ico</lticm:property>
        <lticm:property name="text">Embed Quizlet Flash Cards</lticm:property>
        <lticm:property name="selection_width">690</lticm:property>
        <lticm:property name="selection_height">510</lticm:property>
      </lticm:options>
    </blti:extensions>
    <blti:icon>#{host}/khan.ico</blti:icon>
  XML
end

get "/config/tools.xml" do
  host = request.scheme + "://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  config_wrap <<-XML
    <blti:title>Public Resource Libraries</blti:title>
    <blti:description>Collection of resources from multiple sources, including Kahn Academy, Quizlet, etc.</blti:description>
    <blti:launch_url>#{host}/tool_redirect</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="editor_button">
        <lticm:property name="url">#{host}/tool_redirect?url=#{CGI.escape('/tools.html')}</lticm:property>
        <lticm:property name="icon_url">#{host}/tools.png</lticm:property>
        <lticm:property name="text">Search Resource Libraries</lticm:property>
        <lticm:property name="selection_width">800</lticm:property>
        <lticm:property name="selection_height">600</lticm:property>
      </lticm:options>
    </blti:extensions>
    <blti:icon>#{host}/khan.ico</blti:icon>
  XML
end

post "/tool_redirect" do
  url = params['url']
  args = []
  params.each do |key, val|
    args << "#{CGI.escape(key)}=#{CGI.escape(val)}" if key.match(/^custom_/) || ['launch_presentation_return_url', 'selection_directive'].include?(key)
  end
  url = url + (url.match(/\?/) ? "&" : "?") + args.join('&')
  redirect to(url)
end

get "/oembed" do
  url = params['url']
  code = CGI.unescape(url.split(/code=/)[1])
  {
    'version' => '1.0',
    'type'    => 'rich',
    'html'    => code,
    'width'   => 600,
    'height'  => 400
  }.to_json
end