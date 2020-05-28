import json, tables, asyncdispatch

# almost always use together
export json, asyncdispatch

type 
  ThreadProxyError* = object of CatchableError

  ThreadNotFoundError* = object of ThreadProxyError
    ## Raised when thread with name cannot be found
    threadName*: string

  ReceiverNotFoundError* = object of ThreadProxyError
    ## Raised whenever thread with name not found
    sender*: string
    receiver*: string

  MessageUndeliveredError* = object of ThreadProxyError
    ## Raised when message cannot be send to channel
    kind*: ThreadMessageKind
    action*: string
    sender*: string
    data*: JsonNode

  ActionConflictError* = object of ThreadProxyError
    ## Raised when registering action with non-unique name
    threadName*: string
    action*: string

  NameConflictError* = object of ThreadProxyError
    ## Raise when creating thread with non-unique name
    threadName*: string

  PollConflictError* = object of ThreadProxyError
    ## Raise when poll() is called while ThreadProxy is running
    threadName*: string

  ThreadMessageKind = enum
    EMIT, REQUEST, REPLY, SYS

  SysMsg = enum 
    GET_NAME_REQ, GET_NAME_REP

  ThreadMessage* = object
    kind: ThreadMessageKind
    action: string
    json: JsonNode
    # means sender in REQ/REP
    # means channel in GET_NAME_REP
    channel: ThreadChannelPtr  
    callbackId: int
      
  ThreadChannel* = Channel[ThreadMessage]
  ThreadChannelPtr* = ptr Channel[ThreadMessage]

  ThreadActionHandler* = proc(data: JsonNode): Future[JsonNode] {.gcsafe.}
  ThreadDefaultActionHandler* = proc(action: string, data: JsonNode): Future[JsonNode] {.gcsafe.}

  ThreadProxy* = ref object of RootObj
    active: bool
    name: string
    mainFastChannel, fastChannel, channel: ThreadChannelPtr
    actions: Table[string, ThreadActionHandler]
    defaultAction: ThreadDefaultActionHandler
    callbackSeed: int
    jsonCallbacks: Table[int, Future[JsonNode]]
    channelCallbacks: Table[int, Future[ThreadChannelPtr]]
    directory: Table[string, ThreadChannelPtr] # local cache 

  ThreadChannelWrapper = ref object
    # manually manage memory to prevent GC
    self: ThreadChannelPtr

  ThreadWrapper = ref object
    # manually manage memory to prevent GC
    self: ptr Thread[ThreadProxy]


  ThreadChannelPair = ref object
    channel, fastChannel: ThreadChannelWrapper

  MainThreadProxy* = ref object of ThreadProxy
    channels: Table[string, ThreadChannelPair]
    threads: Table[string, ThreadWrapper]

  ThreadToken* = object
    name: string
    mainFastChannel, fastChannel, channel: ThreadChannelPtr

  ThreadMainProc* = proc(proxy: ThreadProxy) {.thread, nimcall.}

proc finalize(ch: ThreadChannelWrapper) =
  ch.self[].close()
  deallocShared(ch.self)

proc newThreadChannel(channelMaxItems: int): ThreadChannelWrapper =
  result.new(finalize)
  result.self = cast[ThreadChannelPtr](allocShared0(sizeof(ThreadChannel)))
  result.self[].open(channelMaxItems)

# proc newThreadChannelPair(channelMaxItems: int): ThreadChannelPair =
#   result.new()
#   result.channel = newThreadChannel(channelMaxItems)
#   result.fastChannel = newThreadChannel(0)

proc finalize(th: ThreadWrapper) =
  dealloc(th.self)

proc newThread(): ThreadWrapper =
  result.new(finalize)
  result.self = cast[ptr Thread[ThreadProxy]](alloc0(sizeof(Thread[ThreadProxy])))
  
proc defaultAction(action: string, data: JsonNode): Future[JsonNode] {.async.} =
  # default action should ignore the message 
  # echo "No handler for action: " & action & ", " & $data
  return nil

proc newThreadProxy*(token: ThreadToken): ThreadProxy =
  ## Create a new ThreadProxy
  ThreadProxy(
    name: token.name,
    mainFastChannel: token.mainFastChannel,
    fastChannel: token.fastChannel,
    channel: token.channel,
    callbackSeed: 0, 
    jsonCallbacks: initTable[int, Future[JsonNode]](),
    actions: initTable[string, ThreadActionHandler](),
    defaultAction: defaultAction
  )

proc newMainThreadProxy*(name: string, channelMaxItems: int = 0): MainThreadProxy =
  ## Create a new MainThreadProxy
  let ch = newThreadChannel(channelMaxItems)
  let fch = newThreadChannel(0)
  var channels = initTable[string, ThreadChannelPair]()
  channels[name] = ThreadChannelPair(
    channel: ch,
    fastChannel: fch
  )
  MainThreadProxy(
    name: name,
    mainFastChannel: fch.self,
    fastChannel: fch.self,
    channel: ch.self,
    callbackSeed: 0,
    jsonCallbacks: initTable[int, Future[JsonNode]](),
    actions: initTable[string, ThreadActionHandler](),
    defaultAction: defaultAction,
    channels: channels
  )
    
proc newMessage(
  proxy: ThreadProxy, 
  kind: ThreadMessageKind, 
  action: string, 
  data: JsonNode = nil, 
  callbackId: int = 0
): ThreadMessage =
  ThreadMessage(
    kind: kind,
    channel: proxy.channel,
    action: action,
    json: if data.isNil: newJNull() else: data,
    callbackId: callbackId
  ) 

proc newSysMessage(
  action: string, 
  channel: ThreadChannelPtr,
  data: JsonNode = nil, 
  callbackId: int = 0
): ThreadMessage =
  ThreadMessage(
    kind: SYS,
    action: action,
    channel: channel,
    json: if data.isNil: newJNull() else: data,
    callbackId: callbackId
  ) 

proc name*(proxy: ThreadProxy): string {.inline.} = proxy.name

proc isNameAvailable*(proxy: MainThreadProxy, name: string): bool {.inline.} = name notin proxy.channels

proc isMainThreadProxy(proxy: ThreadProxy): bool {.inline.} = proxy.fastChannel == proxy.mainFastChannel

proc isRunning*(proxy: ThreadProxy): bool {.inline.} = 
  ## Check if `proxy` is running 
  proxy.active

proc nextCallbackId(proxy: ThreadProxy): int {.inline.} = 
  # start with 1, callbackId = 0 means no callbacks
  proxy.callbackSeed += 1
  result = proxy.callbackSeed

proc on*(proxy: ThreadProxy, action: string, handler: ThreadActionHandler) =
  ## Set `handler` for `action`
  if action in proxy.actions:
    var err = newException(ActionConflictError, "Action " & action & " has already defined")
    err.threadName = proxy.name
    err.action = action 
    raise err
  proxy.actions[action] = handler

proc onDefault*(proxy: ThreadProxy, handler: ThreadDefaultActionHandler) =
  ## Set default `handler`
  proxy.defaultAction = handler

template onData*(proxy: ThreadProxy, action: string, body: untyped): void =    
  ## Template version of `on`
  proxy.on(
    action, 
    proc(json: JsonNode): Future[JsonNode] {.gcsafe,async.} = 
      let data {.inject.} = json
      `body`
  )

template onDefaultData*(proxy: ThreadProxy, body: untyped) =
  ## Template version of `onDefault`
  proxy.onDefault proc(a: string, j: JsonNode): Future[JsonNode] {.gcsafe,async.} =
    let action {.inject.} = a
    let data {.inject.} = j
    `body`
  
proc send*(proxy: ThreadProxy, target: ThreadChannelPtr, action: string, data: JsonNode): Future[void] =
  ## Send `data` to `target` channel and then complete.
  ## Raise MessageUndeliveredError if cannot put on to target channel. 
  result = newFuture[void]("send")
  let sent = target[].trySend proxy.newMessage(EMIT, action, data) 
  if sent: 
    result.complete()
  else: 
    let err = newException(MessageUndeliveredError, "failed to send")
    err.action = action
    err.kind = EMIT
    err.data = data
    err.sender = proxy.name
    result.fail(err)

proc ask*(proxy: ThreadProxy, target: ThreadChannelPtr, action: string, data: JsonNode = nil): Future[JsonNode] =
  ## Send `data` to `target` channel and then wait for reply
  let id = proxy.nextCallbackId() 
  result = newFuture[JsonNode]("ask")
  proxy.jsonCallbacks[id] = result
  let sent = target[].trySend proxy.newMessage(REQUEST, action, data, id)
  if not sent:
    proxy.jsonCallbacks.del(id)
    let err = newException(MessageUndeliveredError, "failed to send")
    err.action = action
    err.kind = EMIT
    err.data = data
    err.sender = proxy.name
    result.fail(err)

proc getChannel*(proxy: ThreadProxy, name: string): Future[ThreadChannelPtr] =
  ## Resolve name to channel
  
  if proxy.isMainThreadProxy:
    # get from channels
    let mainProxy = cast[MainThreadProxy](proxy)
    let chp = mainProxy.channels.getOrDefault(name, nil)
    if not chp.isNil:
      result = newFuture[ThreadChannelPtr]("getChannel")
      result.complete(chp.channel.self)
    else:
      var err = newException(ReceiverNotFoundError, "Cannot not find " & name)
      err.sender = proxy.name
      err.receiver = name
      result = newFuture[ThreadChannelPtr]("getChannel")
      result.fail(err)
  else:
    # try to get from local directory
    let ch = proxy.directory.getOrDefault(name, nil)
    if not ch.isNil:
      result = newFuture[ThreadChannelPtr]("getChannel")
      result.complete(ch)
    else:
      # ask mainThreadProxy for channel pointer
      let id = proxy.nextCallbackId()
      result = newFuture[ThreadChannelPtr]("getChannel")
      proxy.channelCallbacks[id] = result
      # reply to fast Channel
      proxy.mainFastChannel[].send newSysMessage($GET_NAME_REQ, proxy.fastChannel, %name, id)
  

proc send*(proxy: ThreadProxy, target: string, action: string, data: JsonNode = nil): Future[void] {.async.} =
  ## put one message to `target`'s channel
  let ch = await proxy.getChannel(target)
  await proxy.send(ch, action, data)

proc ask*(proxy: ThreadProxy, target: string, action: string, data: JsonNode = nil): Future[JsonNode] {.async.} =
  ## put one message to target's channel and complete until `target`'s response
  let ch = await proxy.getChannel(target)
  result = await proxy.ask(ch, action, data)

proc processEvent(proxy: ThreadProxy, event: ThreadMessage) =
  # for debug
  # echo proxy.name, event

  case event.kind:
  of EMIT:
    let action = event.action
    let data = event.json
    if action in proxy.actions:
      let cb = proxy.actions[action]
      asyncCheck cb(data)
    elif not proxy.defaultAction.isNil:
      asyncCheck proxy.defaultAction(action, data)
  of REPLY:
    let id = event.callbackId
    let future = proxy.jsonCallbacks.getOrDefault(id, nil)
    if not future.isNil:
      proxy.jsonCallbacks.del id
      future.complete(event.json)
    # else already called 
  of REQUEST:
    let action = event.action
    let target = event.channel
    let data = event.json
    let id = event.callbackId
    if action in proxy.actions:
      let cb = proxy.actions[action]  
      let future = cb(data)
      future.addCallback proc(f: Future[JsonNode]) =
        target[].send proxy.newMessage(REPLY, action, f.read, id) 
    elif not proxy.defaultAction.isNil:
      let future = proxy.defaultAction(action, data)
      future.addCallback proc(f: Future[JsonNode]) =
        target[].send proxy.newMessage(REPLY, action, f.read, id)
  of SYS:
    case event.action
    of $GET_NAME_REQ:
      let name = event.json.getStr()
      let sender = event.channel
      # only MainThreadProxy should receive name_req
      let mainProxy = cast[MainThreadProxy](proxy)
      let chp = mainProxy.channels.getOrDefault(name, nil)
      if chp.isNil:
        # cannot find name, send back with sender channel pointer
        sender[].send newSysMessage($GET_NAME_REP, sender, %name, event.callbackId)
      else:
        # found and reply
        sender[].send newSysMessage($GET_NAME_REP, chp.fastChannel.self, %name, event.callbackId)
    of $GET_NAME_REP:
      let name = event.json.getStr()
      let ch = event.channel
      let id = event.callbackId
      let cb = proxy.channelCallbacks.getOrDefault(id, nil)
      if ch == proxy.channel:
        # not found
        if not cb.isNil: 
          proxy.channelCallbacks.del id
          var err = newException(ReceiverNotFoundError, "Cannot find " & name)
          err.sender = proxy.name
          err.receiver = name 
          cb.fail(err)
      else: 
        # found
        proxy.directory[name] = ch
        if not cb.isNil: 
          proxy.channelCallbacks.del id
          cb.complete(ch)
    else:
      raise newException(Defect, "Unknown system action " & event.action)
  
proc process*(proxy: ThreadProxy): bool =
  ## Process one message on channel. Return false if channel is empty, otherwise true.
  
  # process fast channel first if tryRecv success
  block:
    let (hasData, event) = proxy.fastChannel[].tryRecv()
    if hasData:
      proxy.processEvent(event)
      return true

  # process normal channel
  block:
    let (hasData, event) = proxy.channel[].tryRecv()
    result = hasData
    if hasData: proxy.processEvent(event)


proc stop*(proxy: ThreadProxy) {.inline.} = proxy.active = false

proc poll*(proxy: ThreadProxy, interval: int = 16): Future[void] =
  ## Start processing channel messages.
  ## Raise PollConflictError if proxy is already running
  var future = newFuture[void]("poll")
  result = future

  proc loop() {.gcsafe.} =
    if proxy.active:
      if proxy.process():
        # callSonn allow other async task to run
        if proxy.active: callSoon loop
        else: future.complete()
      else:
        sleepAsync(interval).addCallback(loop)
        # addTimer(interval, true, proc(fd: AsyncFD): bool = loop())
    else:
      future.complete()

  if proxy.active:
    var err = newException(PollConflictError, "ThreadProxy is already started")
    err.threadName = proxy.name
    result.fail(err)
  else:
    proxy.active = true
    loop()

proc createToken*(proxy: MainThreadProxy, name: string, channelMaxItems: int = 0): ThreadToken =
  ## Create token for new threadproxy
  
  # Check name availability
  if not proxy.isNameAvailable(name):
    var err = newException(NameConflictError, "Name " & name & " has already used")
    err.threadName = name
    raise err

  # check new channel
  let ch = newThreadChannel(channelMaxItems)
  let fch = newThreadChannel(0)
  proxy.channels[name] = ThreadChannelPair(
    channel: ch,
    fastChannel: fch
  )
  return ThreadToken(
    name: name,
    mainFastChannel: proxy.fastChannel,
    channel: ch.self,
    fastChannel: fch.self
  )

proc createThread*(proxy: MainThreadProxy, name: string, main: ThreadMainProc, channelMaxItems: int = 0) =
  ## Create new thread managed by `proxy` with an unique `name`
  
  # createToken will check name availability
  let token = proxy.createToken(name, channelMaxItems)

  # create thread wrapper to prevent GC
  let thread = newThread()
  proxy.threads[name] = thread

  # run new thread
  let proxyToDeepCopy = newThreadProxy(token)
  createThread(thread.self[], main, proxyToDeepCopy)

proc pinToCpu*(proxy: MainThreadProxy, name: string, cpu: Natural) =
  ## Pin thread `name` to cpu. Raise ThreadNotFoundError if name not found.
  if name in proxy.threads:
    let err = newException(ThreadNotFoundError, "Cannot find thread with name " & name)
    err.threadName = name
    raise err
  let thread = proxy.threads[name]
  pinToCpu(thread.self[], cpu)
  
proc isThreadRunning*(proxy: MainThreadProxy, name: string): bool =
  ## Check whether thread is running. Applicable only to threads created with `createThread`
  if name in proxy.threads:
    let err = newException(ThreadNotFoundError, "Cannot find thread with name " & name)
    err.threadName = name
    raise err
  let thread = proxy.threads[name]
  result = running(thread.self[])