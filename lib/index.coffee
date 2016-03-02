# THIS ONE IS IN THE CURRENT EDITROOMLIVE APP AND WORKING

cookieParser = require 'cookie-parser'
# cookieParserUtils = require 'cookie-parser/lib/parse'
express = require 'express'
expressLayer = require 'express/lib/router/layer'
expressSession = require 'express-session'
io = require 'socket.io'
http = require 'http'
https = require 'https'
async = require 'async'
middleware = require './middleware'
_ = require 'underscore'

RequestIO = require('./request').RequestIO
RoomIO = require('./room').RoomIO

express.io = io
express.io.routeForward = middleware.routeForward

session = expressSession

# delete express.session
sessionConfig = new Object
# sessionInit = (options) ->
#     options ?= new Object
#     options.key ?= 'connect.sid'
#     options.secret = options.key
#     options.store ?= new session.MemoryStore
#     options.cookie ?= new Object
#     sessionConfig = options
#     return session options

# express.use sessionInit()
# copies methods of the express-session back over - not really required now
# for key, value of session
#     console.log 'session key val:', key, value
#     express.session[key] = value

# console.log('express.io new session check:', express.session); # un-executed thing
express.application.http = ->
    @server = http.createServer this
    return this

express.application.https = (options) ->
    @server = https.createServer options, this
    return this

express.application.io = (options) ->
    options ?= new Object
    
    # for key, value of @
        # try 
            # console.log 'express app val store check:', key, (value + "").indexOf('store')
            # if (value + "").indexOf('store') > -1 then console.log value + ""
        # catch err
            # console.log 'not stringable', key, value
        
        # console.log 'express app:', key, value

    defaultOptions = log:false
    _.defaults options, defaultOptions
    sessionConfig.store ?= options.store
    sessionConfig.secret ?= options.secret
    sessionConfig.session ?= options.session
    # redis store is breaking this now offf
    # session object is now passed?
    # var io = require('socket.io');
    # var socket = io({ /* options */ });
    # console.log 'express.io init socket.io', options # options.store is throwing some weirdness here
    @io = io @server, options
    @io.router = new Object
    # @io.middleware = []
    @io.route = (route, next, options) ->
        # console.log('express.io route:', route);
        if options?.trigger is true
            if route.indexOf ':' is -1
                @router[route] next
            else
                split = route.split ':'
                @router[split[0]][split[1]] next
        if _.isFunction next
            @router[route] = next
        else
            for key, value of next
                @router["#{route}:#{key}"] = value
    # here we go for socket.io 1.x have to change this
    #     io.use(function(socket, next) {
    #   var handshakeData = socket.request;
    #   // make sure the handshake data looks good as before
    #   // if error do this:
    #     // next(new Error('not authorized');
    #   // else just call next
    #   next();
    # });
    @io.use (socket, next) =>
        data = socket.request
        # console.log('socketio middleware:');
        unless options.store?  # changed sessionConfig to instead use a passed session store in options
            # console.log ' - no options.store:', options
            return async.forEachSeries @io.middleware, (callback, next) ->
                callback(data, next)
            , (error) ->
                return next error if error?
                next null, true
        parser = cookieParser()
        # console.log ' - using cookie parser'
        parser data, null, (error) ->
            # console.log ' - parser func data:', data.cookies
            return next error if error?
            rawCookie = data.cookies # data.cookies[sessionConfig.key]
            # console.log ' - parser rawCookie:', rawCookie
            unless rawCookie?
                request = headers: cookie: data.query.cookie
                return parser request, null, (error) ->
                    data.cookies = request.cookies
                    rawCookie = data.cookies #[sessionConfig.key]
                    return next "No cookie present", false unless rawCookie?
                    sessionId = cookieParser.signedCookies rawCookie, options.secret
                    # console.log('what up cookie parser:', rawCookie, sessionId)
                    data.sessionID = sessionId
                    options.store.get sessionId, (error, session) ->
                        return next error if error?
                        data.session = new expressSession.Session data, session
                        next null, true
            
            # console.log 'parser going to check signed cookies with raw cookie:', rawCookie, options.secret
            sessionId = cookieParser.signedCookies rawCookie, options.secret
            # console.log 'io found a session id:', sessionId
            # console.log('req.sessionID:', req.sessionID[app.sessionSecret]);
            # var sessionData = JSON.parse(app.sessionStore.sessions[req.sessionID[app.sessionSecret]]);
            # console.log(sessionData);
            data.sessionID = sessionId[options.secret] # extract the real sessionIdD here
            options.store.get data.sessionID, (error, session) ->
                return next error if error?
                socket.request.session = new expressSession.Session data, session
                # console.log 'custom session store get in express.io:', socket.request.session
                next null, true

    # @io.use = (callback) =>
    #     @io.middleware.push callback

    @io.sockets.on 'connection', (socket) =>
        initRoutes socket, @io

    @io.broadcast = =>
        args = Array.prototype.slice.call arguments, 0
        @io.sockets.emit.apply @io.sockets, args

    @io.room = (room) =>
        new RoomIO(room, @io.sockets)  
    
    
    layer = new expressLayer('',
        sensitive: undefined
        strict: undefined
        end: false
    , (request, response, next) =>
        # console.log('express.io socket layer middleware go');
        request.io =
            route: (route) =>
                ioRequest = new Object
                for key, value of request
                    ioRequest[key] = value
                ioRequest.io =
                    broadcast: @io.broadcast
                    respond: =>
                        args = Array.prototype.slice.call arguments, 0
                        response.json.apply response, args
                    route: (route) =>
                        @io.route route, ioRequest, trigger: true
                    data: request.body
                @io.route route, ioRequest, trigger: true
            broadcast: @io.broadcast
        next()
    )
    # console.log @_router.stack
    @_router.stack.push layer
    return this

# override default listen method, checking if this.server is defined, using that method then...
listen = express.application.listen
express.application.listen = ->
    args = Array.prototype.slice.call arguments, 0
    if @server?
        @server.listen.apply @server, args
    else
        listen.apply this, args
        
# initRoutes - called on new socket connection.
initRoutes = (socket, io) ->
    # console.log 'express.io initRoutes socket check:', socket.request.session
    setRoute = (key, callback) ->
        socket.on key, (data, respond) ->
            # console.log 'express.io socket on handler'
            if typeof data is 'function'
                respond = data
                data = undefined
            request =
                data: data
                session: socket.request.session
                sessionID: socket.request.sessionID
                sessionStore: sessionConfig.store
                socket: socket
                headers: socket.request.headers
                cookies: socket.request.cookies
                handshake: socket.request
            session = socket.request.session
            # console.log('express.io set route socket on:', key, session)
            request.session = new expressSession.Session request, session if session?
            socket.handshake.session = request.session
            request.io = new RequestIO(socket, request, io)
            request.io.respond = respond
            request.io.respond ?= ->
            callback request

    for key, value of io.router
        setRoute(key, value)


module.exports = express
