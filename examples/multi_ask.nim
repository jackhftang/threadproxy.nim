import threadproxy, sugar

const M = 40

proc fib(x: int): int = 
  if x <= 1: 1 
  else: fib(x-1) + fib(x-2)

proc workerMain(proxy: ThreadProxy) {.thread.} =
  # register action handler
  proxy.onData "fib":
    let x = data.getInt()
    return %*{
      "name": proxy.name,
      "y": fib(x)
    }

  # poll until proxy stop
  waitFor proxy.poll()

proc main() =
  let proxy = newMainThreadProxy("master")
  asyncCheck proxy.poll()

  # create N worker threads
  let N = 4
  for i in 0 ..< N:
    proxy.createThread("worker_" & $i, workerMain)

  # distribute M jobs to threads
  var done = 0
  for x in 1..M:
    capture x:
      let name = "worker_" & $(x mod N)
      echo "ask ", name, " for fib(", x, ")"
      let future = proxy.ask(name, "fib", %x)
      future.addCallback:
        let data = future.read()
        let worker = data["name"].getStr()
        let y = data["y"].getInt()
        echo "result from ", worker, " fib(", x,") = ", y
        done.inc
        if done >= M:
          proxy.stop()
  
  while proxy.isRunning:
    poll()

  

when isMainModule:
  main()