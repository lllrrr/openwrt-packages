export interface FrpcProxyStats {
  proxies: FrpcProxy[];
}

export interface FrpcProxy {
  name: string;
  type: string;
  // frp: client/proxy/proxy_wrapper.go
  status:
    | "new"
    | "wait start"
    | "start error"
    | "running"
    | "check failed"
    | "closed"
    | "error";
  err: string;
  cfg: FrpcConfig;
  remote_addr: string;
}

export interface FrpcConfig {
  name: string;
  type: string;
  transport: FrpcTransport;
  loadBalancer: FrpcLoadBalancer;
  healthCheck: FrpcHealthCheck;
  localIP: string;
  localPort: number;
  plugin: null;
  remotePort: number;
}

export interface FrpcHealthCheck {
  type: string;
  intervalSeconds: number;
}

export interface FrpcLoadBalancer {
  group: string;
}

export interface FrpcTransport {
  useEncryption: boolean;
  useCompression: boolean;
  bandwidthLimit: string;
}
