require 'active_support/core_ext/class/attribute_accessors'

require 'tkellem/irc_server'
require 'tkellem/bouncer_connection'

module Tkellem

class Bouncer
  include Tkellem::EasyLogger

  attr_reader :user, :network, :nick, :network_user, :connected_at
  cattr_accessor :plugins
  self.plugins = []

  def initialize(network_user)
    @network_user = network_user
    @user = network_user.user
    @network = network_user.network

    @nick = network_user.nick
    # maps { client_conn => state_hash }
    @active_conns = {}
    @welcomes = []
    @rooms = []
    # maps { client_conn => away_status_or_nil }
    @away = {}
    # plugin data
    @data = {}
    # clients waiting for us to connect to the irc server
    @waiting_clients = []

    connect!
  end

  def data(key)
    @data[key] ||= {}
  end

  def active_conns
    @active_conns.keys
  end

  def self.add_plugin(plugin)
    self.plugins << plugin
  end

  def connected?
    !!@connected
  end

  def connect_client(client)
    @active_conns[client] = {}
    @away[client] = nil

    if !connected?
      @waiting_clients << client
      client.say_as_tkellem("Connecting you to the IRC server. Please wait...")
      return
    end

    # force the client nick
    client.send_msg(":#{client.connecting_nick} NICK #{nick}") if client.connecting_nick != nick
    send_welcome(client)
    # make the client join all the rooms that we're in
    @rooms.each { |room| client.simulate_join(room) }

    plugins.each { |plugin| plugin.new_client_connected(self, client) }
    check_away_status
  end

  def disconnect_client(client)
    @away.delete(client)
    check_away_status
    @active_conns.delete(client)
  end

  def client_msg(client, msg)
    return if plugins.any? do |plugin|
      !plugin.client_msg(self, client, msg)
    end

    forward = case msg.command
    when 'PING'
      client.send_msg(":tkellem!tkellem PONG tkellem :#{msg.args.last}")
      false
    when 'AWAY'
      @away[client] = msg.args.last
      check_away_status
      false
    when 'NICK'
      @nick = msg.args.last
      true
    else
      true
    end

    if forward
      # send to server
      send_msg(msg)
    end
  end

  def server_msg(msg)
    return if plugins.any? do |plugin|
      !plugin.server_msg(self, msg)
    end

    forward = case msg.command
    when /0\d\d/, /2[56]\d/, /37[256]/
      @welcomes << msg
      ready! if msg.command == "376" # end of MOTD
      false
    when 'JOIN'
      debug "#{msg.target_user} joined #{msg.args.last}"
      @rooms << msg.args.last if msg.target_user == @nick
      true
    when 'PART'
      debug "#{msg.target_user} left #{msg.args.last}"
      @rooms.delete(msg.args.last) if msg.target_user == @nick
      true
    when 'PING'
      send_msg("PONG tkellem!tkellem :#{msg.args.last}")
      false
    when 'PONG'
      # swallow it, we handle ping-pong from clients separately, in
      # BouncerConnection
      false
    when '433'
      # nick already in use, try another
      change_nick("#{@nick}_")
      false
    when 'NICK'
      if msg.prefix == nick
        @nick = msg.args.last
      end
      true
    else
      true
    end

    if forward
      # send to clients
      @active_conns.each { |c,s| c.send_msg(msg) }
    end
  end

  ## Away Statuses

  def check_away_status
    # for now we pretty much randomly pick an away status if multiple are set
    # by clients
    if @away.any? { |k,v| !v }
      # we have a client who isn't away
      send_msg("AWAY")
    else
      message = @away.values.first || "Away"
      send_msg("AWAY :#{message}")
    end
  end


  def name
    "#{user.name}-#{network.name}"
  end
  alias_method :log_name, :name

  def send_msg(msg)
    return unless @conn
    trace "to server: #{msg}"
    @conn.send_data("#{msg}\r\n")
  end

  def connection_established(conn)
    @conn = conn
    # TODO: support sending a real username, realname, etc
    send_msg("USER #{@user.username} somehost tkellem :#{@user.name}@tkellem")
    change_nick(@nick, true)
    @connected_at = Time.now
  end

  def disconnected!
    debug "OMG we got disconnected."
    @conn = nil
    @connected = false
    @connected_at = nil
    @active_conns.each { |c,s| c.close_connection }
    connect!
  end

  protected

  def change_nick(new_nick, force = false)
    return if !force && new_nick == @nick
    @nick = new_nick
    send_msg("NICK #{new_nick}")
  end

  def send_welcome(bouncer_conn)
    @welcomes.each { |msg| msg.args[0] = nick; bouncer_conn.send_msg(msg) }
  end

  def connect!
    @connector ||= IrcServerConnection.connector(self, network)
    @connector.connect!
  end

  def ready!
    @rooms.each do |room|
      send_msg("JOIN #{room}")
    end

    check_away_status

    # We're all initialized, allow connections
    @connected_at = Time.now
    @connected = true

    @network_user.combined_at_connect.each do |line|
      msg = IrcMessage.parse_client_command(line)
      send_msg(msg) if msg
    end

    @waiting_clients.each do |client|
      client.say_as_tkellem("Now connected.")
      connect_client(client)
    end
    @waiting_clients.clear
  end

end

end
