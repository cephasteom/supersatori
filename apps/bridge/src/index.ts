import WebSocket, { WebSocketServer } from 'ws'
import osc from 'osc'
import fs from 'fs'
import path from 'path'

declare type Event = {
  id: string,
  params: Record<string, any>,
  time: number, // in cycles, e.g. 1, 2.25, 3.065 etc.
  type: string,
  cps: number
};

interface OscArg {
  type: 's' | 'i' | 'f'
  value: string | number
}

type JsonPrimitive = string | number | boolean | null
type JsonValue = JsonPrimitive | JsonValue[]

const oscOut = new osc.UDPPort({
  remoteAddress: '127.0.0.1',
  remotePort: 57120
})

oscOut.open()

const synthdefsPath = path.resolve(__dirname, '../../synth/synthdefs.json')

const wss = new WebSocketServer({ port: 8080 })

function toOscArg(value: JsonValue): OscArg | null {
  if (Array.isArray(value))       return { type: 's', value: value.join(',') }
  if (typeof value === 'string')  return { type: 's', value }
  if (typeof value === 'boolean') return { type: 'i', value: value ? 1 : 0 }
  if (typeof value === 'number')  return Number.isInteger(value)
    ? { type: 'i', value }
    : { type: 'f', value }
  return null
}

const typeMap: Record<string, string> = {
  e: 'event',
  m: 'mutation'
}

wss.on('connection', ws => {
  try {
    ws.send(fs.readFileSync(synthdefsPath, 'utf8'))
  } catch {
    // synthdefs.json not yet written — SC may still be booting
  }

  ws.on('message', raw => {
    const msg = JSON.parse(raw.toString()) as Event
    const msgType = typeMap[msg.type] ?? 'event'
    const address = `/satori/${msg.id}/${msgType}`
    const args = [
      { type: 's' as const, value: 'cps' }, { type: 'f' as const, value: msg.cps ?? 0.5 },
      { type: 's' as const, value: 'time' }, { type: 'f' as const, value: msg.time ?? 0 },
      ...Object.entries(msg.params).flatMap(([key, val]) => {
        if(key === 'e' || key === 'm') return [] // skip type field
        const oscVal = toOscArg(val as JsonPrimitive)
        if (!oscVal) return []
        return [{ type: 's' as const, value: key }, oscVal]
      })
    ]

    oscOut.send({ address, args })
  })
})
