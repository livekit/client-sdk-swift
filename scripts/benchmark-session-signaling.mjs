import net from 'node:net';
const sockets = new Set();
const timers = new Set();
const oneWayMs = Number(process.env.ONE_WAY_MS ?? 50);
const upstreamPort = Number(process.env.SFU_PORT || 17880);
const listenPort = Number(process.env.RELAY_PORT || 17883);
const server = net.createServer(client => {
  const upstream = net.connect(upstreamPort, '127.0.0.1');
  for (const socket of [client, upstream]) sockets.add(socket);
  for (const [source, destination] of [[client, upstream], [upstream, client]]) {
    let pending = 0;
    source.on('data', chunk => {
      pending += chunk.byteLength;
      if (pending + destination.writableLength > 1024 * 1024) source.pause();
      const timer = setTimeout(() => {
        timers.delete(timer);
        pending -= chunk.byteLength;
        if (!destination.destroyed) destination.write(chunk);
        if (pending + destination.writableLength < 512 * 1024 && !source.destroyed) source.resume();
      }, oneWayMs);
      timers.add(timer);
    });
    destination.on('drain', () => { if (pending < 512 * 1024) source.resume(); });
    source.on('error', () => destination.destroy());
    source.on('close', () => { sockets.delete(source); destination.destroy(); });
  }
});
server.listen(listenPort, '127.0.0.1', () => console.log(`Signaling relay: ws://127.0.0.1:${listenPort}, added RTT=${oneWayMs * 2}ms`));
function stop() {
  for (const timer of timers) clearTimeout(timer);
  for (const socket of sockets) socket.destroy();
  server.close();
}
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
