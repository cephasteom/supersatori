declare module 'osc' {
  interface UDPPortOptions {
    remoteAddress: string
    remotePort: number
    localAddress?: string
    localPort?: number
  }

  interface OscArg {
    type: string
    value: unknown
  }

  interface OscMessage {
    address: string
    args: OscArg[]
  }

  class UDPPort {
    constructor(options: UDPPortOptions)
    open(): void
    send(message: OscMessage): void
  }

  export default { UDPPort }
}
