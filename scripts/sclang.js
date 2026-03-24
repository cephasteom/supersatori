const { spawn } = require('child_process')
const path = require('path')

const sclangPaths = {
  darwin: '/Applications/SuperCollider.app/Contents/MacOS/sclang',
  linux:  'sclang',
  win32:  'C:\\Program Files\\SuperCollider\\sclang.exe'
}

const sclang = sclangPaths[process.platform] ?? 'sclang'
const scd = path.resolve(__dirname, '../apps/synth/main.scd')

const proc = spawn(sclang, [scd], { stdio: 'inherit' })
proc.on('exit', code => process.exit(code ?? 0))
