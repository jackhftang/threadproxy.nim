import unittest
import threadproxy
import json

proc workerMain(proxy: ThreadProxy) {.thread.} =

  proxy.onData "ping":
    return data

  proxy.onData "resend":
    asyncCheck proxy.send("main", "recev", data)

  asyncCheck proxy.poll()


  runForever()

# proc barMain(proxy: ThreadProxy) {.thread.} =
#   proxy.onData "ping":
#     echo proxy.name, " receive ", data
#   asyncCheck proxy.poll()

#   asyncCheck proxy.send("foo", "ping", %"hello world from bar")
#   runForever()

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


    
    
