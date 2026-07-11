'use strict';

// Supergateway currently calls server.listen(port) and has no effective bind
// address option. Preload this file into its Node process so only xcbox's
// configured gateway port is forced onto host loopback.
const net = require('node:net');

const port = Number.parseInt(process.env.XCBOX_FORCE_LOOPBACK_PORT ?? '', 10);
const host = process.env.XCBOX_FORCE_LOOPBACK_HOST ?? '127.0.0.1';
const patchMarker = Symbol.for('xcbox.forceLoopbackPatched');

if (Number.isInteger(port) && port > 0 && port <= 65535 && !net.Server.prototype[patchMarker]) {
  const originalListen = net.Server.prototype.listen;

  net.Server.prototype.listen = function forceXcboxGatewayLoopback(...args) {
    const target = args[0];

    if (target && typeof target === 'object' && Number(target.port) === port) {
      args[0] = { ...target, host };
    } else if (Number(target) === port) {
      if (typeof args[1] === 'string') args[1] = host;
      else args.splice(1, 0, host);
    }

    return originalListen.apply(this, args);
  };

  Object.defineProperty(net.Server.prototype, patchMarker, { value: true });
}
