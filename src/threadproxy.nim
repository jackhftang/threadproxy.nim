when not(compileOption("threads")):
  {.fatal: "--threads:on is required for threadproxy".}

import json, tables, asyncdispatch, sets

# almost always use together
export json, asyncdispatch

type 
  ThreadProxyError* = object of CatchableError

  ThreadNotFoundError* = object of ThreadProxyError
    ## Raised when operation on thread with name `threadName` cannot be found
    threadName*: string

  ThreadUncleanableError* = object of ThreadProxyError
    ## Raised when thread cannot be clean-up
    threadName*: string

  ReceiverNotFoundError* = object of ThreadProxyError
    ## Raised whenever sending a message to unknown receiver
    sender*: string
    receiver*: string

  MessageUndeliveredError* = object of ThreadProxyError
    ## Raised when message cannot be send to channel
    kind*: ThreadMessageKind
    action*: string
    sender*: string
    data*: JsonNode

  ActionConflictError* = object of ThreadProxyError
    ## Raised when registering action is not unique
    threadName*: string
    action*: string

  NameConflictError* = object of ThreadProxyError
    ## Raised when name of thread is not unique
    threadName*: string

  PollConflictError* = object of ThreadProxyError
    ## Raised when poll() is called while ThreadProxy is running
    threadName*: string

  HandlerIsNilError* = object of ThreadProxyError
    ## Raised when handler is nil

  ResponseError* = object of ThreadProxyError
    ## Raised when the opposite failed to reply
    action*: string
    errorMessage*: string

  ThreadMessageKind = enum
    EMIT, REQUEST, REPLY_SUCCESS, REPLY_FAIL, SYS

  SysMsg = enum 
    GET_NAME_REQ, GET_NAME_REP, 
    DEL_NAME_REQ, DEL_NAME_REP

  ThreadMessage = ref object
    kind: ThreadMessageKind
    action: string
    json: JsonNode
    # means sender in REQ/REP
    # means channel in GET_NAME_REP
    channel: ThreadChannelPtr  
    callbackId: int
      
  ThreadChannel = Channel[ThreadMessage]
  ThreadChannelPtr = ptr Channel[ThreadMessage]

  ThreadActionHandler* = proc(data: JsonNode): Future[JsonNode] {.gcsafe.}
    ## Signature for action handler 
    
  ThreadDefaultActionHandler* = proc(action: string, data: JsonNode): Future[JsonNode] {.gcsafe.}
    ## Signature for default action handler 

  ThreadProxy* = ref object of RootObj
    active: bool
    name: string
    mainFastChannel, fastChannel, channel: ThreadChannelPtr
    actions: Table[string, ThreadActionHandler]
    defaultAction: ThreadDefaultActionHandler
    callbackSeed: int
    jsonCallbacks: Table[int, Future[JsonNode]]
    channelCallbacks: Table[int, Future[ThreadChannelPtr]]
    ## local cache to resolve name to channel
    directory: Table[string, ThreadChannelPtr] 

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
    ## Signature for entry function of thread

proc finalize(ch: ThreadChannelWrapper) =
  if not ch.self.isNil:
    ch.self[].close()
    deallocShared(ch.self)
    ch.self = nil

proc newThreadChannel(channelMaxItems: int): ThreadChannelWrapper =
  result.new(finalize)
  result.self = cast[ThreadChannelPtr](allocShared0(sizeof(ThreadChannel)))
  result.self[].open(channelMaxItems)

proc finalize(th: ThreadWrapper) =
  if not th.self.isNil:
    dealloc(th.self)
    th.self = nil

proc newThread(): ThreadWrapper =
  result.new(finalize)
  result.self = cast[ptr Thread[ThreadProxy]](alloc0(sizeof(Thread[ThreadProxy])))
  
proc defaultAction(action: string, data: JsonNode): Future[JsonNode] {.async.} =
  # default action should ignore the message 
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
    callbackId: callbackId,
  ) 

proc newFailureMessage(
  proxy: ThreadProxy,
  action: string,
  errMsg: string,
  callbackId: int
): ThreadMessage =
  ThreadMessage(
    kind: REPLY_FAIL,
    channel: proxy.channel,
    action: action,
    json: %errMsg,
    callbackId: callbackId,
  )

proc newSysMessage(
  action: SysMsg, 
  channel: ThreadChannelPtr,
  data: JsonNode = nil, 
  callbackId: int = 0
): ThreadMessage =
  ThreadMessage(
    kind: SYS,
    action: $action,
    channel: channel,
    json: if data.isNil: newJNull() else: data,
    callbackId: callbackId
  ) 

proc name*(proxy: ThreadProxy): string {.inline.} = 
  ## Get the name of thread 
  proxy.name

proc isNameAvailable*(proxy: MainThreadProxy, name: string): bool {.inline.} = 
  ## Chekc if the name is available to use
  name notin proxy.channels

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
  if handler.isNil:
    raise newException(HandlerIsNilError, "Handler cannot be nil")
  proxy.actions[action] = handler

proc onDefault*(proxy: ThreadProxy, handler: ThreadDefaultActionHandler) =
  ## Set default `handler` for all unhandled action
  if handler.isNil:
    raise newException(HandlerIsNilError, "Handler cannot be nil")
  proxy.defaultAction = handler

template onData*(proxy: ThreadProxy, action: string, body: untyped): void =    
  ## Template version of `on`, saving you from typing `proc(data: JsonNode): Future[JsonNode] {.gcsafe,async.} = ...` every time. 
  ## The argument `data` is injected and so the name *onData*.
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

proc send(proxy: ThreadProxy, target: ThreadChannelPtr, action: string, data: JsonNode): Future[void] =
  result = newFuture[void]("send")
  let sent = target[].trySend proxy.newMessage(EMIT, action, data) 
  if sent: 
    result.complete()
  else: 
    let err = newException(MessageUndeliveredError, "Failed to send message to target")
    err.action = action
    err.kind = EMIT
    err.data = data
    err.sender = proxy.name
    result.fail(err)

proc ask(proxy: ThreadProxy, target: ThreadChannelPtr, action: string, data: JsonNode = nil): Future[JsonNode] =
  let id = proxy.nextCallbackId() 
  result = newFuture[JsonNode]("ask")
  proxy.jsonCallbacks[id] = result
  let sent = target[].trySend proxy.newMessage(REQUEST, action, data, id)
  if not sent:
    proxy.jsonCallbacks.del(id)
    let err = newException(MessageUndeliveredError, "Failed to send message to target")
    err.action = action
    err.kind = EMIT
    err.data = data
    err.sender = proxy.name
    result.fail(err)

proc getChannel(proxy: ThreadProxy, name: string): Future[ThreadChannelPtr] =
  ## Resolve name to channel
  
  if proxy.isMainThreadProxy:
    # get from channels
    let mainProxy = cast[MainThreadProxy](proxy)
    let ch = mainProxy.directory.getOrDefault(name, nil)
    if not ch.isNil:
      result = newFuture[ThreadChannelPtr]("getChannel")
      result.complete(ch)
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
      proxy.mainFastChannel[].send newSysMessage(GET_NAME_REQ, proxy.fastChannel, %name, id)
  

proc send*(proxy: ThreadProxy, target: string, action: string, data: JsonNode = nil): Future[void] {.async.} =
  ## Send `data` to `target` channel. 
  ## 
  ## The returned future complete once the message is successfully placed on target channel.
  ## otherwise fail with MessageUndeliveredError.
  let ch = await proxy.getChannel(target)
  await proxy.send(ch, action, data)

proc ask*(proxy: ThreadProxy, target: string, action: string, data: JsonNode = nil): Future[JsonNode] {.async.} =
  ## Send `data` to `target` and wait for the return.
  ## 
  ## The returned future will complete with the result from target is received. It may fail with many kind of errors.
  let ch = await proxy.getChannel(target)
  result = await proxy.ask(ch, action, data)

proc processEvent(proxy: ThreadProxy, event: ThreadMessage) =
  # for debug
  # echo proxy.name, event[]

  case event.kind:
  of EMIT:
    let action = event.action
    let data = event.json
    if action in proxy.actions:
      let cb = proxy.actions[action]
      asyncCheck cb(data)
    elif not proxy.defaultAction.isNil:
      asyncCheck proxy.defaultAction(action, data)
  of REQUEST:
    let action = event.action
    let target = event.channel
    let data = event.json
    let id = event.callbackId
    let future =
      if action in proxy.actions:
        proxy.actions[action](data)
      else:
        proxy.defaultAction(action, data)
    future.addCallback proc(f: Future[JsonNode]) =
      if unlikely(f.failed):
        let err = f.readError
        target[].send proxy.newFailureMessage(err.msg, action, id)
        # raise in local thread, same behavior as asyncCheck in send
        raise err
      else:
        target[].send proxy.newMessage(REPLY_SUCCESS, action, f.read, id)
  of REPLY_SUCCESS:
    let id = event.callbackId
    let future = proxy.jsonCallbacks.getOrDefault(id, nil)
    if likely(not future.isNil):
      proxy.jsonCallbacks.del id
      future.complete(event.json)
    # else already called 
  of REPLY_FAIL:
    let id = event.callbackId
    let action = event.action
    let errMsg = event.json.getStr()
    let future = proxy.jsonCallbacks.getOrDefault(id, nil)
    if likely(not future.isNil):
      proxy.jsonCallbacks.del id
      let err = newException(ResponseError, "Failure response")
      err.action = action
      err.errorMessage = errMsg
      # todo: the error message is strange...
      future.fail(err)
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
        sender[].send newSysMessage(GET_NAME_REP, sender, %name, event.callbackId)
      else:
        # found and reply
        sender[].send newSysMessage(GET_NAME_REP, chp.fastChannel.self, %name, event.callbackId)
    of $GET_NAME_REP:
      let name = event.json.getStr()
      let ch = event.channel
      let id = event.callbackId
      let cb = proxy.channelCallbacks.getOrDefault(id, nil)
      if ch == proxy.fastChannel:
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
    of $DEL_NAME_REQ:
      let names = event.json
      let mainChannel = event.channel
      let id = event.callbackId
      for name in names:
        proxy.directory.del name.getStr()
      mainChannel[].send newSysMessage(DEL_NAME_REP, proxy.fastChannel, %proxy.name, id)
    of $DEL_NAME_REP:
      let id = event.callbackId
      let future = proxy.jsonCallbacks[id]
      if likely(not future.isNil):
        proxy.jsonCallbacks.del id
        future.complete(event.json)
    else:
      raise newException(Defect, "Unknown system action " & event.action)
  
proc process*(proxy: ThreadProxy): bool {.gcsafe.} =
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


proc stop*(proxy: ThreadProxy) {.inline.} = 
  ## Stop processing messages. The future returned from `poll()` will complete.
  proxy.active = false

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
  proxy.directory[name] = ch.self
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
  if name notin proxy.threads:
    let err = newException(ThreadNotFoundError, "Cannot find thread with name " & name)
    err.threadName = name
    raise err
  let thread = proxy.threads[name]
  result = running(thread.self[])

# import sequtils
# proc debugPrint*(proxy: ThreadProxy) =
#   echo proxy.name
#   if proxy of MainThreadProxy:
#     let proxy = cast[MainThreadProxy](proxy)
#     echo "  channels: ", toSeq(proxy.channels.keys)
#     echo "  threads: ", toSeq(proxy.threads.keys)
#   echo "  directory: ", toSeq(proxy.directory.keys)

proc deleteThread(proxy: MainThreadProxy, name: string) =
  # this is do not clean up directory, use cleanThread 
  let th = proxy.threads[name]
  th.finalize()
  proxy.threads.del(name)

  let ch = proxy.channels[name]
  ch.channel.finalize()
  ch.fastChannel.finalize()
  proxy.channels.del(name)

proc cleanThreads*(proxy: MainThreadProxy): Future[void] =
  ## Clean up resource of non-running threads
  
  let ret = newFuture[void]("cleanThread")
  result = ret

  # separate active and inactive threads
  var 
    actives: seq[string]
    inactives: seq[string]
  for n, _ in proxy.directory:
    if proxy.isThreadRunning(n):
      actives.add n
    else:
      inactives.add n

  # return if nothing to do
  if inactives.len == 0:
    ret.complete()
    return
    
  # delete from directory to prevent new GET_NAME_REQ
  for n in inactives:
    proxy.directory.del n
    
  # ask threads to delete directory of inactives
  var targets = actives.toHashSet()
  for target in actives:
    # ask all threads to delete directory
    let id = proxy.nextCallbackId()
    # todo: add timeout for failure detection
    let future = newFuture[JsonNode]("cleanThread")
    proxy.jsonCallbacks[id] = future
    future.addCallback proc(f: Future[JsonNode]) =
      if f.failed: 
        ret.fail(f.readError)
      else:
        targets.excl f.read.getStr()
        if targets.len == 0:
          # after recieve all responds, delete resources
          for n in inactives:
            proxy.deleteThread n
          ret.complete()

    # send to thread
    let chp = proxy.channels[target]
    chp.fastChannel.self[].send newSysMessage(DEL_NAME_REQ, proxy.fastChannel, %inactives, id)
  
  # no thread to wait, just complete
  if actives.len == 0: 
    for n in inactives:
      proxy.deleteThread n
      ret.complete()
  
