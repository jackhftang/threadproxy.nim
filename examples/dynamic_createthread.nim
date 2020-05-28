import threadproxy

proc workerMain(proxy: ThreadProxy) {.thread.} =
  proxy.onData "run":
    # ask master to create new thread and sent to new worker by name
    echo proxy.name, " ask master to create new thread"
    let name = await proxy.ask("master", "createThread")
    echo proxy.name, " send run to ", name.getStr()
    await proxy.send(name.getStr(), "run")
  waitFor proxy.poll()

proc main() =
  let proxy = newMainThreadProxy("master")
  var cnt = 0

  proxy.onData "createThread":
    if cnt == 10: 
      proxy.stop()
    else:
      cnt.inc
      let name = "worker_" & $cnt
      echo "master is creating thread ", name      
      proxy.createThread(name, workerMain)
      return %name

  echo "master is starting worker_0"
  proxy.createThread("worker_0", workerMain)
  waitFor proxy.send("worker_0", "run")

  waitFor proxy.poll()
  echo "done"

when isMainModule:
  main()


  