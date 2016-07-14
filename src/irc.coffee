# Hubot dependencies
{Robot, Adapter, TextMessage, EnterMessage, LeaveMessage, Response} = require 'hubot'

# Custom Response class that adds a sendPrivate method
class IrcResponse extends Response
  sendPrivate: (strings...) ->
    @robot.adapter.sendPrivate @envelope, strings...

# Irc library
Irc = require 'irc-framework'

Log = require('log')
logger = new Log process.env.HUBOT_LOG_LEVEL or 'info'

class IrcBot extends Adapter
  send: (envelope, strings...) ->
    # Use @notice if SEND_NOTICE_MODE is set
    return @notice envelope, strings if process.env.HUBOT_IRC_SEND_NOTICE_MODE?

    target = @_getTargetFromEnvelope envelope

    unless target
      return logger.error "ERROR: Not sure who to send to. envelope=", envelope

    for str in strings
      for strline in str.split('\n')
        logger.info "#{target} #{strline}"
        @bot.say target, strline

  sendPrivate: (envelope, strings...) ->
    # Remove the room from the envelope and send as private message to user
    logger.info 'sendPrivate'

    if envelope.room
      delete envelope.room

    if envelope.user?.room
      delete envelope.user.room

    @send envelope, strings...

  topic: (envelope, strings...) ->
    data = strings.join " / "
    channel = envelope.room
    @bot.send 'TOPIC', channel, data

  emote: (envelope, strings...) ->
    # Use @notice if SEND_NOTICE_MODE is set
    return @notice envelope, strings if process.env.HUBOT_IRC_SEND_NOTICE_MODE?

    target = @_getTargetFromEnvelope envelope

    unless target
      return logger.error "ERROR: Not sure who to send to. envelope=", envelope

    for str in strings
      @bot.action target, str

  notice: (envelope, strings...) ->
    target = @_getTargetFromEnvelope envelope

    unless target
      return logger.warn "Notice: no target found", envelope

    # Flatten out strings from send
    flattened = []
    for str in strings
      if typeof str != 'undefined'
        for line in str.toString().split(/\r?\n/)
          if Array.isArray line
            flattened = flattened.concat line
          else
            flattened.push line

    for str in flattened
      if not str?
        continue

      @bot.notice target, str

  reply: (envelope, strings...) ->
    for str in strings
      @send envelope.user, "#{envelope.user.name}: #{str}"

  join: (channel) ->
    self = @
    @bot.join channel, () ->
      logger.info('joined %s', channel)

      selfUser = self.getUserFromName self.robot.name
      self.receive new EnterMessage(selfUser)

  part: (channel) ->
    self = @
    @bot.part channel, () ->
      logger.info('left %s', channel)

      selfUser = self.getUserFromName self.robot.name
      self.receive new LeaveMessage(selfUser)

  getUserFromName: (name) ->
    return @robot.brain.userForName(name) if @robot.brain?.userForName?

    # Deprecated in 3.0.0
    return @userForName name

  getUserFromId: (id) ->
    # TODO: Add logic to convert object if name matches
    return @robot.brain.userForId(id) if @robot.brain?.userForId?

    # Deprecated in 3.0.0
    return @userForId id

  createUser: (channel, from) ->
    user = @getUserFromId from
    user.name = from

    if channel.match(/^[&#]/)
      user.room = channel
    else
      user.room = null
    user

  kick: (channel, client, message) ->
    @bot.emit 'raw',
      command: 'KICK'
      nick: process.env.HUBOT_IRC_NICK
      args: [ channel, client, message ]

  command: (command, strings...) ->
    @bot.send command, strings...

  checkCanStart: ->
    if not process.env.HUBOT_IRC_NICK and not @robot.name
      throw new Error("HUBOT_IRC_NICK is not defined; try: export HUBOT_IRC_NICK='mybot'")
    else if not process.env.HUBOT_IRC_ROOMS
      throw new Error("HUBOT_IRC_ROOMS is not defined; try: export HUBOT_IRC_ROOMS='#myroom'")
    else if not process.env.HUBOT_IRC_SERVER
      throw new Error("HUBOT_IRC_SERVER is not defined: try: export HUBOT_IRC_SERVER='irc.myserver.com'")

  unfloodProtection: (unflood) ->
    unflood == 'true' or !isNaN(parseInt(unflood))

  unfloodProtectionDelay: (unflood) ->
    unfloodProtection = @unfloodProtection(unflood)
    unfloodValue = parseInt(unflood) or 1000

    if unfloodProtection
      unfloodValue
    else
      0

  run: ->
    self = @

    do @checkCanStart

    options =
      nick:     process.env.HUBOT_IRC_NICK or @robot.name
      realName: process.env.HUBOT_IRC_REALNAME
      port:     process.env.HUBOT_IRC_PORT
      rooms:    process.env.HUBOT_IRC_ROOMS.split(",")
      ignoreUsers: process.env.HUBOT_IRC_IGNORE_USERS?.split(",") or []
      server:   process.env.HUBOT_IRC_SERVER
      password: process.env.HUBOT_IRC_PASSWORD
      nickpass: process.env.HUBOT_IRC_NICKSERV_PASSWORD
      nickusername: process.env.HUBOT_IRC_NICKSERV_USERNAME
      connectCommand: process.env.HUBOT_IRC_CONNECT_COMMAND
      fakessl:  process.env.HUBOT_IRC_SERVER_FAKE_SSL?
      certExpired: process.env.HUBOT_IRC_SERVER_CERT_EXPIRED?
      unflood:  process.env.HUBOT_IRC_UNFLOOD
      debug:    process.env.HUBOT_IRC_DEBUG?
      usessl:   process.env.HUBOT_IRC_USESSL?
      userName: process.env.HUBOT_IRC_USERNAME

    client_options =
      server:
        host: options.server
        port: options.port
      nickname: options.nick
      username: options.userName
      realname: options.realName
      password: options.password
      #debug: options.debug
      #stripColors: true
      #secure: options.usessl
      #selfSigned: options.fakessl
      #certExpired: options.certExpired
      #floodProtection: @unfloodProtection(options.unflood),
      #floodProtectionDelay: @unfloodProtectionDelay(options.unflood),

    client_options['channels'] = options.rooms unless options.nickpass

    # Override the response to provide a sendPrivate method
    @robot.Response = IrcResponse

    @robot.name = options.nick
    bot = new Irc.Client
    bot.connect host: options.server, nick: options.nick, username: options.userName, password: options.password
    bot.on 'raw', (e) ->
        logger.info "RAW: " + e
    bot.on 'registered', () ->
        bot.join room for room in options.rooms

    next_id = 1
    user_id = {}

    if options.nickpass?
      identify_args = ""

      if options.nickusername?
        identify_args += "#{options.nickusername} "

      identify_args += "#{options.nickpass}"

      bot.addListener 'notice', (from, to, text) ->
        if from is 'NickServ' and text.toLowerCase().indexOf('identify') isnt -1
          bot.say 'NickServ', "identify #{identify_args}"
        else if options.nickpass and from is 'NickServ' and
                (text.indexOf('Password accepted') isnt -1 or
                 text.indexOf('identified') isnt -1)
          for room in options.rooms
            @join room

    if options.connectCommand?
      bot.addListener 'registered', (message) ->
        # The 'registered' event is fired when you are connected to the server
        strings = options.connectCommand.split " "
        self.command strings.shift(), strings...

    bot.addListener 'names', (channel, nicks) ->
      for nick of nicks
        self.createUser channel, nick

    bot.addListener 'notice', (event) ->
      if event.nick in options.ignoreUsers
        logger.info('Ignoring user: %s', event.nick)
        # we'll ignore this message if it's from someone we want to ignore
        return

      logger.info "NOTICE from #{event.nick} to #{event.target}: #{event.message}"

      user = self.createUser event.target, event.nick
      self.receive new TextMessage(user, event.message)

    bot.addListener 'message', (event) ->
      if options.nick.toLowerCase() == event.target.toLowerCase()
        # this is a private message, let the 'pm' listener handle it
        return

      if event.nick in options.ignoreUsers
        logger.info('Ignoring user: %s', event.nick)
        # we'll ignore this message if it's from someone we want to ignore
        return

      logger.debug "From #{event.nick} to #{event.target}: #{event.message}"

      user = self.createUser event.target, event.nick
      if user.room
        logger.debug "#{event.target} <#{event.nick}> #{event.message}"
      else
        unless event.message.indexOf(event.target) == 0
          message = "#{event.target}: #{event.msg}"
        logger.debug "msg <#{event.nick}> #{event.msg}"

      self.receive new TextMessage(user, event.message)

    bot.addListener 'action', (event) ->
      logger.debug " * From #{event.nick} to #{event.target}: #{event.message}"

      if event.nick in options.ignoreUsers
        logger.info('Ignoring user: %s', from)
        # we'll ignore this message if it's from someone we want to ignore
        return

      user = self.createUser event.target, event.nick
      if user.room
        logger.debug "#{event.target} * #{event.nick} #{event.message}"
      else
        logger.debug "msg <#{event.nick}> #{event.message}"

      self.receive new TextMessage(user, event.message)

    #bot.addListener 'error', (message) ->
    #  logger.error('ERROR: %s: %s', message.command, message.args.join(' '))

    bot.addListener 'privmsg', (event) ->
      logger.info('Got private message from %s: %s', event.nick, event.message)

      if process.env.HUBOT_IRC_PRIVATE
        return

      if event.nick in options.ignoreUsers
        logger.info('Ignoring user: %s', nick)
        # we'll ignore this message if it's from someone we want to ignore
        return

      nameLength = options.nick.length
      if event.message.slice(0, nameLength).toLowerCase() != options.nick.toLowerCase()
        message = "#{options.nick} #{event.message}"
      else
        message = event.message

      self.receive new TextMessage({reply_to: event.nick, name: event.nick}, 'message')

    bot.addListener 'join', (event) ->
      logger.info('%s has joined %s', event.nick, event.channel)
      user = self.createUser event.channel, event.nick
      user.room = event.channel
      self.receive new EnterMessage(user)

    bot.addListener 'part', (event) ->
      logger.info('%s has left %s: %s', event.nick, event.channel, event.message)
      user = self.createUser '', event.nick
      user.room = event.channel
      msg = new LeaveMessage user
      msg.text = event.message
      self.receive msg

    bot.addListener 'quit', (event) ->
      logger.info '%s has quit: %s', event.nick, event.message
      #for ch in channels
      #  user = self.createUser '', who
      #  user.room = ch
      #  msg = new LeaveMessage user
      #  msg.text = reason
      #  self.receive msg

    bot.addListener 'kick', (event) ->
      logger.info('%s was kicked from %s by %s: %s', event.nick, event.channel, event.kicked, event.message)

    bot.addListener 'invite', (event) ->
      logger.info('%s invited you to join %s', event.nick, event.channel)

      if event.invited in options.ignoreUsers
        logger.info('Ignoring user: %s', from)
        # we'll ignore this message if it's from someone we want to ignore
        return

      if not process.env.HUBOT_IRC_PRIVATE or process.env.HUBOT_IRC_IGNOREINVITE
        bot.join channel

    @bot = bot

    self.emit "connected"

  _getTargetFromEnvelope: (envelope) ->
    user = null
    room = null
    target = null

    # as of hubot 2.4.2, the first param to send() is an object with 'user'
    # and 'room' data inside. detect the old style here.
    if envelope.reply_to
      user = envelope
    else
      # expand envelope
      user = envelope.user
      room = envelope.room

    if user
      # most common case - we're replying to a user in a room
      if user.room
        target = user.room
      # reply directly
      else if user.name
        target = user.name
      # replying to pm
      else if user.reply_to
        target = user.reply_to
      # allows user to be an id string
      else if user.search?(/@/) != -1
        target = user
    else if room
      # this will happen if someone uses robot.messageRoom(jid, ...)
      target = room

    target

exports.use = (robot) ->
  new IrcBot robot
