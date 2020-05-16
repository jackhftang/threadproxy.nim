import json, tables, asyncdispatch

# almost always use together
export json, asyncdispatch

type 
  ThreadProxyError* = object of CatchableError
  TargetNotFoundError* = object of ThreadProxyError
    sender: string
    target: string
  ActionConflictError* = object of ThreadProxyError
    action: string
  MessageUndeliveredError* = object of ThreadProxyError
    kind: ThreadMessageKind
    action: string
    sender: string
    data: JsonNode
  
  ThreadMessageKind* = enum
    EMIT, 
    REQUEST, REPLY,
    SYS

  SysMsg = enum 
    GET_NAME_REQ, GET_NAME_REP

  ThreadMessage* = object
    kind: ThreadMessageKind
    action: string
    data: JsonNode
    sender: ThreadChannelPtr  # or data in SYS_REP
    callbackId: int
      
  ThreadChannel* = Channel[ThreadMessage]
  ThreadChannelPtr* = ptr Channel[ThreadMessage]

  ThreadActionHandler* = proc(data: JsonNode): Future[JsonNode] {.gcsafe.}
  ThreadDefaultActionHandler* = proc(action: string, data: JsonNode): Future[JsonNode] {.gcsafe.}

  ThreadProxy* = ref object of RootObj
    name: string
    mainChannel, channel: ThreadChannelPtr
    callbackSeed: int
    callbacks: Table[int, Future[JsonNode]]
    actions: Table[string, ThreadActionHandler]
    defaultAction: ThreadDefaultActionHandler
    directory: Table[string, ThreadChannelPtr] # local cache 
    nameCallbacks: Table[int, Future[ThreadChannelPtr]]

  ThreadChannelWrapper = ref object
    # manually manage memory to prevent GC
    self: ThreadChannelPtr

  ThreadWrapper = ref object
    # manually manage memory to prevent GC
    self: ptr Thread[ThreadProxy]

  MainThreadProxy* = ref object of ThreadProxy
    channels: Table[string, ThreadChannelWrapper]
    threads: Table[string, ThreadWrapper]

  ThreadToken* = object
    name: string
    mainChannel, channel: ThreadChannelPtr

  ThreadMainProc* = proc(proxy: ThreadProxy) {.thread, nimcall.}

proc finalize(ch: ThreadChannelWrapper) =
  ch.self[].close()
  deallocShared(ch.self)

proc newThreadChannel(): ThreadChannelWrapper =
  result.new(finalize)
  result.self = cast[ThreadChannelPtr](allocShared0(sizeof(ThreadChannel)))
  result.self[].open()

proc finalize(th: ThreadWrapper) =
  dealloc(th.self)

proc newThread(): ThreadWrapper =
  result.new(finalize)
  result.self = cast[ptr Thread[ThreadProxy]](alloc0(sizeof(Thread[ThreadProxy])))
  
proc defaultAction(action: string, data: JsonNode): Future[JsonNode] {.async.} =
  echo "No handler for action: " & action & ", " & $data
  return nil

proc newThreadProxy*(token: ThreadToken): ThreadProxy =
  ThreadProxy(
    name: token.name,
    mainChannel: token.mainChannel,
    channel: token.channel,
    callbackSeed: 1, # avoid the use of 0
    callbacks: initTable[int, Future[JsonNode]](),
    actions: initTable[string, ThreadActionHandler](),
    defaultAction: defaultAction
  )

proc newMainThreadProxy*(name: string): MainThreadProxy =
  let ch = newThreadChannel()
  var channels = initTable[string, ThreadChannelWrapper]()
  channels[name] = ch
  MainThreadProxy(
    name: name,
    mainChannel: ch.self,
    channel: ch.self,
    callbackSeed: 1,
    callbacks: initTable[int, Future[JsonNode]](),
    actions: initTable[string, ThreadActionHandler](),
    defaultAction: defaultAction,
    channels: channels
  )
    
proc newMessage*(
  proxy: ThreadProxy, 
  kind: ThreadMessageKind, 
  action: string, 
  data: JsonNode = nil, 
  callbackId: int = 0
): ThreadMessage =
  ThreadMessage(
    kind: kind,
    sender: proxy.channel,
    action: action,
    data: if data.isNil: newJNull() else: data,
    callbackId: callbackId
  ) 

proc newSysMessage*(
  action: string, 
  channel: ThreadChannelPtr,
  data: JsonNode = nil, 
  callbackId: int = 0
): ThreadMessage =
  ThreadMessage(
    kind: SYS,
    action: action,
    sender: channel,
    data: if data.isNil: newJNull() else: data,
    callbackId: callbackId
  ) 

proc name*(proxy: ThreadProxy): string {.inline.} = proxy.name

proc isMainThreadProxy(proxy: ThreadProxy): bool = proxy.channel == proxy.mainChannel

proc on*(proxy: ThreadProxy, action: string, handler: ThreadActionHandler) =
  if action in proxy.actions:
    var err = newException(ActionConflictError, "Action " & action & " has already defined")
    err.action = action 
    raise err
  proxy.actions[action] = handler

proc onDefault*(proxy: ThreadProxy, handler: ThreadDefaultActionHandler) =
  proxy.defaultAction = handler

template onData*(proxy: ThreadProxy, action: string, body: untyped): void =    
  proxy.on(
    action, 
    proc(json: JsonNode): Future[JsonNode] {.gcsafe,async.} = 
      let data {.inject.} = json
      `body`
  )

template onDefaultData*(proxy: ThreadProxy, body: untyped) =
  proxy.onDefault proc(a: string, j: JsonNode): Future[JsonNode] {.gcsafe,async.} =
    let action {.inject.} = a
    let data {.inject.} = j
    `body`
  
proc send*(proxy: ThreadProxy, target: ThreadChannelPtr, action: string, data: JsonNode): Future[void] =
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
  let id = proxy.callbackSeed 
  proxy.callbackSeed += 1
  result = newFuture[JsonNode]("ask")
  proxy.callbacks[id] = result
  let sent = target[].trySend proxy.newMessage(REQUEST, action, data, id)
  if not sent:
    proxy.callbacks.del(id)
    let err = newException(MessageUndeliveredError, "failed to send")
    err.action = action
    err.kind = EMIT
    err.data = data
    err.sender = proxy.name
    result.fail(err)

proc getChannel*(proxy: ThreadProxy, name: string): Future[ThreadChannelPtr] =
  if proxy.isMainThreadProxy:
    let mainProxy = cast[MainThreadProxy](proxy)
    let ch = mainProxy.channels.getOrDefault(name, nil)
    if not ch.isNil:
      result = newFuture[ThreadChannelPtr]("getChannel")
      result.complete(ch.self)
    else:
      var err = newException(TargetNotFoundError, "Cannot not find " & name)
      err.sender = proxy.name
      err.target = name
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
      let id = proxy.callbackSeed 
      proxy.callbackSeed += 1
      result = newFuture[ThreadChannelPtr]("getChannel")
      proxy.nameCallbacks[id] = result
      proxy.mainChannel[].send newSysMessage($GET_NAME_REQ, proxy.channel, %name, id)
  

proc send*(proxy: ThreadProxy, target: string, action: string, data: JsonNode): Future[void] {.async.} =
  let ch = await proxy.getChannel(target)
  await proxy.send(ch, action, data)

proc ask*(proxy: ThreadProxy, target: string, action: string, data: JsonNode = nil): Future[JsonNode] {.async.}=
  let ch = await proxy.getChannel(target)
  result = await proxy.ask(ch, action, data)

proc process*(proxy: ThreadProxy): bool =
  ## Process one message on channel
  let (hasData, event) = proxy.channel[].tryRecv()
  result = hasData
  if not hasData: return

  # for debug
  # echo proxy.name, event

  case event.kind:
  of EMIT:
    let action = event.action
    if action in proxy.actions:
      let cb = proxy.actions[action]
      asyncCheck cb(event.data)
    elif not proxy.defaultAction.isNil:
      asyncCheck proxy.defaultAction(action, event.data)
  of REPLY:
    let id = event.callbackId
    let future = proxy.callbacks.getOrDefault(id, nil)
    if not future.isNil:
      proxy.callbacks.del id
      future.complete(event.data)
    # else already called 
  of REQUEST:
    let action = event.action
    let target = event.sender
    let id = event.callbackId
    if action in proxy.actions:
      let cb = proxy.actions[action]  
      let future = cb(event.data)
      future.addCallback proc(f: Future[JsonNode]) =
        target[].send proxy.newMessage(REPLY, action, f.read, id) 
    elif not proxy.defaultAction.isNil:
      let future = proxy.defaultAction(action, event.data)
      future.addCallback proc(f: Future[JsonNode]) =
        target[].send proxy.newMessage(REPLY, action, f.read, id)
  of SYS:
    case event.action
    of $GET_NAME_REQ:
      let name = event.data.getStr()
      # only MainThreadProxy should receive name_req
      let mainProxy = cast[MainThreadProxy](proxy)
      let ch = mainProxy.channels.getOrDefault(name, nil)
      if ch.isNil:
        # cannot find name, send back with sender channel pointer
        event.sender[].send newSysMessage($GET_NAME_REP, event.sender, %name, event.callbackId)
      else:
        # found and reply
        event.sender[].send newSysMessage($GET_NAME_REP, ch.self, %name, event.callbackId)
    of $GET_NAME_REP:
      let name = event.data.getStr()
      let ch = event.sender
      let id = event.callbackId
      let cb = proxy.nameCallbacks.getOrDefault(id, nil)
      if ch == proxy.channel:
        # not found
        if not cb.isNil: 
          proxy.nameCallbacks.del id
          var err = newException(TargetNotFoundError, "Cannot find " & name)
          err.sender = proxy.name
          err.target = name 
          cb.fail(err)
      else: 
        # found
        proxy.directory[name] = ch
        if not cb.isNil: 
          proxy.nameCallbacks.del id
          cb.complete(ch)
    else:
      raise newException(Defect, "Unknown system action " & event.action)

proc poll*(proxy: ThreadProxy, interval: int = 16): Future[void] {.async.} =
  # instead of while proxy.proces()
  # callSoon provide chance for other async job.
  proc loop() {.gcsafe.} =
    if proxy.process():
      callSoon loop
  while true:
    await sleepAsync(interval)
    loop()
    
proc createToken*(proxy: MainThreadProxy, name: string): ThreadToken =
  let ch = newThreadChannel()
  proxy.channels[name] = ch
  return ThreadToken(
    name: name,
    mainChannel: proxy.channel,
    channel: ch.self
  )

proc createThread*(proxy: MainThreadProxy, name: string, main: ThreadMainProc) =
  let thread = newThread()
  proxy.threads[name] = thread
  let token = proxy.createToken(name)
  let proxy = newThreadProxy(token)
  createThread(thread.self[], main, proxy)