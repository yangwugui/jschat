require 'rubygems'
require 'sinatra'
require 'sha1'
require 'json'
require 'sprockets'
require 'jschat/init'

set :public, File.join(File.dirname(__FILE__), 'public')
set :views, File.join(File.dirname(__FILE__), 'views')
set :sessions, true

module JsChat::Auth
end

module JsChat::Auth::Twitter
  def self.template
    :twitter
  end

  def self.load
    require 'twitter_oauth'
    @loaded = true
  rescue LoadError
    puts 'Error: twitter_oauth gem not found'
    @loaded = false
  end

  def self.loaded?
    @loaded
  end
end

module JsChat
  class ConnectionError < Exception ; end

  def self.configure_authenticators
    if ServerConfig['twitter']
      JsChat::Auth::Twitter.load
    end
  end

  def self.init
    configure_authenticators
    JsChat.init_storage
  end
end

JsChat.init

before do
  if JsChat::Auth::Twitter.loaded?
    @user = session[:user]
    @twitter = TwitterOAuth::Client.new(
      :consumer_key => ServerConfig['twitter']['key'],
      :consumer_secret => ServerConfig['twitter']['secret'],
      :token => session[:access_token],
      :secret => session[:secret_token]
    )
  end
end

# todo: can this be async and allow the server to have multiple threads? 
class JsChat::Bridge
  attr_reader :cookie, :identification_error, :last_error

  def initialize(cookie = nil)
    @cookie = cookie
  end

  def cookie_set?
    !(@cookie.nil? or @cookie.empty?)
  end

  def connect
    response = send_json({ :protocol => 'stateless' })
    @cookie = response['cookie']
  end

  def identify(name, ip)
    response = send_json({ :identify => name, :ip => ip })
    if response['display'] == 'error'
      @identification_error = response
      false
    else
      true
    end
  end

  def rooms
    send_json({ :list => 'rooms' })
  end

  def lastlog(room)
    response = send_json({ :lastlog => room })
    response['messages']
  end

  def recent_messages(room)
    send_json({ 'since' => room })['messages']
  end

  def room_update_times
    send_json({ 'times' => 'all' })
  end

  def join(room)
    send_json({ :join => room }, false)
  end

  def part(room)
    send_json({ :part => room })
  end

  def send_message(message, to)
    send_json({ :send => message, :to => to }, false)
  end

  def active?
    return false unless cookie_set?
    response = ping
    if response.nil? or response['display'] == 'error'
      @last_error = response
      false
    else
      true
    end
  end

  def ping
    send_json({ 'ping' => Time.now.utc })
  end

  def change(change_type, data)
    send_json({ 'change' => change_type, change_type => data })
  end

  def names(room)
    send_json({'names' => room})
  end

  def send_quit(name)
    send_json({'quit' => name })
  end

  def send_json(h, get_results = true)
    response = nil
    h[:cookie] = @cookie if cookie_set?
    c = TCPSocket.open(ServerConfig['ip'], ServerConfig['port'])
    c.send(h.to_json + "\n", 0)
    if get_results
      response = c.gets
      response = JSON.parse(response)
    end
  ensure
    c.close
    response
  end
end

helpers do
  include Rack::Utils
  alias_method :h, :escape_html

  def detected_layout
    iphone_user_agent? ? :iphone : :layout
  end

  def iphone_user_agent?
    request.env["HTTP_USER_AGENT"] && request.env["HTTP_USER_AGENT"][/(Mobile\/.+Safari)/]
  end

  def load_bridge
    @bridge = JsChat::Bridge.new request.cookies['jschat-id']
  end

  def load_and_connect
    @bridge = JsChat::Bridge.new request.cookies['jschat-id']
    @bridge.connect
    response.set_cookie 'jschat-id', @bridge.cookie
  end

  def save_last_room(room)
    response.set_cookie 'last-room', room
  end

  def last_room
    request.cookies['last-room']
  end

  def save_nickname(name)
    response.set_cookie 'jschat-name', name
  end

  def messages_js(messages)
    messages ||= []
    messages.to_json
  end

  def remove_my_messages(messages)
    return if messages.nil?
    messages.delete_if { |message| message['message'] and message['message']['user'] == nickname }
  end

  def clear_cookies
    response.set_cookie 'last-room', nil
    response.set_cookie 'jschat-id', nil
    session[:user] = nil
    session[:request_token] = nil
    session[:request_token_secret] = nil
    session[:access_token] = nil
    session[:secret_token] = nil
  end

  def save_user(options = {})
    # FIXME: User name is used as the unique ID and we're letting people change their name
    JsChat::Storage.driver.save_user(options.merge(load_user.merge({
      'name'         => nickname,
      'access_token' => session[:access_token],
      'secret_token' => session[:secret_token]
    })))
  end

  def load_user
    if session[:access_token] 
      JsChat::Storage.driver.find_user({ 'access_token' => session[:access_token] }) || {}
    else
      {}
    end
  end

  def nickname
    request.cookies['jschat-name']
  end
end

# Identify
get '/' do
  load_bridge

  if @bridge.active? and last_room
    redirect "/chat/#{last_room}" 
  else
    clear_cookies
    erb :index, :layout => detected_layout
  end
end

post '/identify' do
  load_and_connect
  save_last_room params['room']
  save_nickname params['name']
  if @bridge.identify params['name'], request.ip
    { 'action' => 'redirect', 'to' => "/chat/#{params['room']}" }.to_json
  else
    @bridge.identification_error.to_json
  end
end

post '/change-name' do
  load_bridge
  [@bridge.change('user', { 'name' => params['name'] })].to_json
end

get '/messages' do
  load_bridge
  if @bridge.active?
    save_last_room params['room']
    messages_js remove_my_messages(@bridge.recent_messages(params['room']))
  else
    if @bridge.last_error and @bridge.last_error['error']['code'] == 107
      error 500, [@bridge.last_error].to_json 
    else
      [@bridge.last_error].to_json
    end
  end
end

get '/room_update_times' do
  load_bridge
  if @bridge.active?
    messages_js @bridge.room_update_times
  end
end

get '/names' do
  load_bridge
  save_last_room params['room']
  [@bridge.names(params['room'])].to_json
end

get '/lastlog' do
  load_bridge
  if @bridge.active?
    save_last_room params['room']
    messages_js @bridge.lastlog(params['room'])
  end
end

post '/join' do
  load_bridge
  @bridge.join params['room']
  save_last_room params['room']
  'OK'
end

get '/part' do
  load_bridge
  @bridge.part params['room']

  if @bridge.last_error
    error 500, [@bridge.last_error].to_json 
  else
    'OK'
  end
end

get '/chat/' do
  load_bridge
  if @bridge and @bridge.active?
    erb :message_form, :layout => detected_layout
  else
    erb :index, :layout => detected_layout
  end
end

post '/message' do
  load_bridge
  save_last_room params['room']
  @bridge.send_message params['message'], params['to']
  'OK'
end

get '/user/name' do
  load_bridge
  nickname
end

get '/ping' do
  load_bridge
  @bridge.ping.to_json
end

get '/quit' do
  load_bridge
  @bridge.send_quit nickname
  load_bridge
  clear_cookies
  redirect '/'
end

get '/rooms' do
  load_bridge
  rooms = @bridge.rooms
  save_user('rooms' => rooms)
  rooms.to_json
end

get '/twitter' do
  request_token = @twitter.request_token(
    :oauth_callback => 'http://localhost:4567/twitter_auth'
  )
  session[:request_token] = request_token.token
  session[:request_token_secret] = request_token.secret
  redirect request_token.authorize_url.gsub('authorize', 'authenticate') 
end

get '/twitter_auth' do
  load_bridge

  # Exchange the request token for an access token.
  begin
    @access_token = @twitter.authorize(
      session[:request_token],
      session[:request_token_secret],
      :oauth_verifier => params[:oauth_verifier]
    )
  rescue OAuth::Unauthorized => exception
    puts exception
  end
  
  if @twitter.authorized?
    # Storing the access tokens so we don't have to go back to Twitter again
    # in this session. In a larger app you would probably persist these details somewhere.
    session[:access_token] = @access_token.token
    session[:secret_token] = @access_token.secret
    session[:user] = true

    # TODO: 1. Make this cope if someone has stolen their name
    #       2. Automatically load name from db
    name = @twitter.info['screen_name']
    room = '#jschat'
    save_last_room room
    save_nickname name
    save_user
    erb :twitter_auth
  else
    redirect '/'
  end
end

# This serves the JavaScript concat'd by Sprockets
# run script/sprocket.rb to cache this
get '/javascripts/all.js' do
  root = File.join(File.dirname(File.expand_path(__FILE__)))
  sprockets_config = YAML.load(IO.read(File.join(root, 'config', 'sprockets.yml')))
  secretary = Sprockets::Secretary.new(sprockets_config.merge(:root => root))
  content_type 'text/javascript'
  secretary.concatenation.to_s
end