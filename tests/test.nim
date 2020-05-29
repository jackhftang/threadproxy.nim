import unittest
import threadproxy
import json

proc workerMain(proxy: ThreadProxy) {.thread.} =
  var active = true

  proxy.onData "ping":
    return data

  proxy.onData "pingTo":
    let future = proxy.ask(data.getStr(), "ping", %proxy.name)
    yield future
    return %( not future.failed )

  proxy.onData "resend":
    asyncCheck proxy.send("main", "recev", data)

  proxy.onData "stop":
    active = false
    proxy.stop()

  proxy.on "failure", proc(j: JsonNode): Future[JsonNode] {.gcsafe,async.} =
    if true:
      raise newException(ValueError, j.getStr())

  proxy.onDefaultData:
    return %*{
      "action": action,
      "data": data
    }

  while active:
    try:
      waitFor proxy.poll()
    except:
      discard

suite "threadproxy":

  test "ask":
    let proxy = newMainThreadProxy("main")
    asyncCheck proxy.poll()

    proxy.createThread("worker1", workerMain)
    
    let a = waitFor proxy.ask("worker1", "ping", %"pong")
    assert a == %"pong"

  test "send":
    let proxy = newMainThreadProxy("main")
    asyncCheck proxy.poll()

    var done = false
    proxy.onData "recev":
      done = data == %"hello"

    proxy.createThread("worker1", workerMain)
    waitFor proxy.send("worker1", "resend", %"hello")

    # worker have to 'resolve name' and 'resend'
    # so, making to 'ask' can make sure 'recev' is done
    discard waitFor proxy.ask("worker1", "ping", %"pong")
    assert not done
    discard waitFor proxy.ask("worker1", "ping", %"pong")
    assert done    

  test "onDefaultData":
    let proxy = newMainThreadProxy("main")
    asyncCheck proxy.poll()

    proxy.createThread("worker1", workerMain)
    
    let a = waitFor proxy.ask("worker1", "some_unknown_action", %"pong")
    assert a == %*{
      "action": "some_unknown_action",
      "data": "pong"
    }

  test "failure - send":
    let run = proc() {.async.} =
      let proxy = newMainThreadProxy("main")
      asyncCheck proxy.poll()
      proxy.createThread("worker1", workerMain)
      let future = proxy.send("worker1", "failure", %"some error message")
      yield future
      assert not future.failed
    waitFor run()

  test "failure - ask":
    let run = proc() {.async.} =
      let proxy = newMainThreadProxy("main")
      asyncCheck proxy.poll()
      proxy.createThread("worker1", workerMain)
      let errMsg = "some error message"
      let future = proxy.ask("worker1", "failure", %errMsg)
      yield future
      assert future.failed
      let err = future.readError
      assert err of ResponseError
      # future inject some unwanted messages
      # assert err.msg == errMsg
    waitFor run()
  
  test "cleanThreads":
    let run = proc() {.async.} =
      let proxy = newMainThreadProxy("main")
      asyncCheck proxy.poll()
      proxy.createThread("worker1", workerMain)
      proxy.createThread("worker2", workerMain)
      proxy.createThread("worker3", workerMain)

      block:
        # worker2 pre-cache worker1 channel, while worker3 not
        let canPing21 = await proxy.ask("worker2", "pingTo", %"worker1")
        assert canPing21.getBool()

      await proxy.send("worker1", "stop")
      while proxy.isThreadRunning("worker1"):
        discard
      await proxy.cleanThreads()

      block:
        let canPing21 = await proxy.ask("worker2", "pingTo", %"worker1")
        assert not canPing21.getBool()
        let canPing31 = await proxy.ask("worker3", "pingTo", %"worker1")
        assert not canPing31.getBool()

    waitFor run()


