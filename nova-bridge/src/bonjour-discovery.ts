import os from "node:os";
import { Bonjour } from "bonjour-service";

export const NOVA_BRIDGE_SERVICE_TYPE = "nova-bridge";

export interface BridgeAdvertisement {
  stop(): void;
}

/**
 * Advertise Nova Bridge on the local network using Bonjour/mDNS.
 *
 * Only public routing metadata is broadcast. The bearer token, repository
 * names, working directories, and API readiness never leave the HTTP API.
 */
export function advertiseBridge(port: number): BridgeAdvertisement {
  const bonjour = new Bonjour(undefined, (error: unknown) => {
    console.warn(`Nova Bridge Bonjour error: ${String(error)}`);
  });
  const hostName = os.hostname();
  const service = bonjour.publish({
    name: `Nova Bridge (${hostName})`,
    type: NOVA_BRIDGE_SERVICE_TYPE,
    protocol: "tcp",
    port,
    txt: {
      version: "1",
      service: "nova-bridge",
    },
  });

  let stopped = false;
  return {
    stop(): void {
      if (stopped) return;
      stopped = true;
      service.stop(() => bonjour.destroy());
    },
  };
}
