// Huebeat's Zigbee bridge. The app spawns this with system Node and talks JSON lines over stdin/stdout.
//
// app -> helper: {"cmd":"color","x":0.7,"y":0.3,"level":200}   latest wins; stale frames are dropped
//                {"cmd":"white","mireds":250,"level":200}        color temperature (153 cool ... 500 warm)
//                {"cmd":"snapshot"}                             remember the bulbs' state when music starts
//                {"cmd":"restore"}                              put them back to that state when it stops
//                {"cmd":"quit"}                                 restore, stop the coordinator, exit (stdin EOF does the same)
// helper -> app: {"event":"ready","port":...,"lights":[...]} | {"event":"sent",...} | {"event":"log"|"error","message":...}
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const {performance} = require('node:perf_hooks');
const {Controller} = require('zigbee-herdsman');
const {setLogger} = require('zigbee-herdsman/dist/utils/logger.js');

// ~/Library/Logs/Huebeat/helper.log: everything sent to the app, plus a sample of incoming commands.
const logFile = path.join(require('node:os').homedir(), 'Library/Logs/Huebeat/helper.log');
fs.mkdirSync(path.dirname(logFile), {recursive: true});
const trace = line => fs.appendFile(logFile, `${new Date().toISOString()} ${line}\n`, () => {});
const emit = (event, fields = {}) => {
  const line = JSON.stringify({event, ...fields});
  if (event !== 'sent') trace(line);
  process.stdout.write(line + '\n');
};
const log = message => emit('log', {message});
const fail = message => emit('error', {message});

const arg = name => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };
const dataDir = arg('--data');
if (!dataDir) { fail('Missing --data directory'); process.exit(2); }

// Never let herdsman fall back to defaults: a mismatched config can make it form a new network and orphan every bulb.
const networkPath = path.join(dataDir, 'network.json');
const databasePath = path.join(dataDir, 'database.db');
const backupPath = path.join(dataDir, 'coordinator-backup.json');
for (const file of [networkPath, databasePath, backupPath]) {
  if (!fs.existsSync(file)) { fail(`Missing ${path.basename(file)} in ${dataDir}. Refusing to start so the existing network isn't replaced.`); process.exit(3); }
}

function findPort() {
  const explicit = arg('--port');
  if (explicit) return explicit;
  const ports = fs.readdirSync('/dev').filter(n => /^cu\.(usbserial|SLAB_USBtoUART|usbmodem)/.test(n)).sort();
  return ports.length ? `/dev/${ports[0]}` : undefined;
}

setLogger({debug() {}, info() {}, warning() {}, error: m => fail(String(m))});

const wait = ms => new Promise(resolve => setTimeout(resolve, Math.max(0, ms)));
const SEND = {timeout: 1000, disableRecovery: true, sendPolicy: 'immediate', disableDefaultResponse: true};
let controller;
let lights = [];      // [{ieee, name, endpoint}]
let originals = [];   // saved bulb state, restored on stop
let pending;          // latest {x, y, level} not yet sent
let lastLevel;
let sending = false;
let shuttingDown = false;
let received = 0;
let session = false;   // a music session is running and owes the bulbs a restore

// Each bulb's state as far as we know: read once at connect, then updated by every manual change.
// Music frames don't count, so a snapshot is always the state the user chose.
const known = new Map();   // ieee -> {color, level, on}

async function readStates() {
  for (const light of lights) {
    try {
      const color = await light.endpoint.read('lightingColorCtrl', ['colorMode', 'currentX', 'currentY', 'colorTemperature'], {timeout: 1500});
      const level = await light.endpoint.read('genLevelCtrl', ['currentLevel'], {timeout: 1500});
      known.set(light.ieee, {color, level: level.currentLevel, on: 1});
    } catch (error) { log(`Couldn't read ${light.name}'s state; Stop will leave it on the last music color.`); }
  }
}

function remember(message) {
  for (const light of lights) {
    const previous = known.get(light.ieee) ?? {on: 1};
    const color = message.cmd === 'white'
      ? {colorMode: 2, colorTemperature: Math.round(message.mireds)}
      : {colorMode: 1, currentX: Math.round(message.x * 65536), currentY: Math.round(message.y * 65536)};
    known.set(light.ieee, {...previous, color, level: Math.round(message.level ?? previous.level ?? 254), on: 1});
  }
}

// Instant: music starts sending right away instead of waiting on slow bulbs to answer reads.
function snapshot() {
  originals = lights.filter(light => known.has(light.ieee)).map(light => ({light, ...known.get(light.ieee)}));
  session = true;
  emit('snapshot');
}

async function restore() {
  if (!session) return;
  session = false;
  pending = undefined;
  while (sending) await wait(10);
  sending = true;
  try {
    for (const {light, color, level, on} of originals) {
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          const opts = {timeout: 2500};
          if (color.colorMode === 2) await light.endpoint.command('lightingColorCtrl', 'moveToColorTemp', {colortemp: color.colorTemperature, transtime: 0}, opts);
          else await light.endpoint.command('lightingColorCtrl', 'moveToColor', {colorx: color.currentX, colory: color.currentY, transtime: 0}, opts);
          if (level !== undefined) await light.endpoint.command('genLevelCtrl', 'moveToLevel', {level, transtime: 0}, opts);
          if (on === 0) await light.endpoint.command('genOnOff', 'off', {}, opts);
          break;
        } catch (error) { if (attempt === 3) log(`Restore failed for ${light.name}: ${error.message}`); }
      }
    }
    lastLevel = undefined;
    emit('restored');
  } finally { sending = false; }
}

// One bulb at a time: parallel unicasts overloaded the coordinator, and group broadcasts are capped at ~1/s.
async function pump() {
  if (sending || shuttingDown) return;
  sending = true;
  try {
    while (pending && !shuttingDown) {
      const {cmd, x, y, mireds, level, exactLevel, transition} = pending;
      const transtime = Math.max(0, Math.min(Math.round(transition ?? 0), 50));
      pending = undefined;
      const colorx = Math.round(Math.min(Math.max(x ?? 0, 0), 0.9999) * 65536);
      const colory = Math.round(Math.min(Math.max(y ?? 0, 0), 0.9999) * 65536);
      // Level is a second command per bulb, so music only sends it when brightness moved noticeably.
      // Manual changes (exactLevel) always send it.
      const sendLevel = Number.isFinite(level) && (exactLevel || lastLevel === undefined || Math.abs(level - lastLevel) >= 40);
      const started = performance.now();
      let failed = 0;
      for (const light of lights) {
        try {
          if (cmd === 'white') await light.endpoint.command('lightingColorCtrl', 'moveToColorTemp', {colortemp: Math.round(mireds), transtime: 0}, SEND);
          else await light.endpoint.command('lightingColorCtrl', 'moveToColor', {colorx, colory, transtime}, SEND);
          if (sendLevel) await light.endpoint.command('genLevelCtrl', 'moveToLevel', {level: Math.round(level), transtime}, SEND);
        } catch { failed++; }
      }
      if (sendLevel) lastLevel = level;
      emit('sent', {ms: Math.round(performance.now() - started), failed});
    }
  } finally { sending = false; }
}

async function shutdown(code = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  // Unresponsive bulbs can stall the restore; never hold the serial port past this.
  setTimeout(() => process.exit(code), 6000).unref();
  try {
    if (controller && lights.length) await restore();
    if (controller) await controller.stop();
  } catch (error) { fail(`Shutdown: ${error.message}`); }
  process.exit(code);
}

async function main() {
  const port = findPort();
  if (!port) { fail('Sonoff dongle not found. Plug it in and press Connect.'); process.exit(4); }
  controller = new Controller({
    network: JSON.parse(fs.readFileSync(networkPath)),
    transport: {path: port, adapter: 'ember', baudRate: 115200, rtscts: false},
    adapter: {disableLED: false, transmitPower: 5, concurrent: 16},
    databasePath, databaseBackupPath: databasePath + '.backup', backupPath,
  });
  try {
    await controller.start();
  } catch (error) {
    fail(/lock|busy|Resource/i.test(error.message) ? `${port} is busy. Another app is using the dongle.` : `Couldn't start the dongle: ${error.message}`);
    process.exit(5);
  }
  controller.on('adapterDisconnected', () => { fail('The Sonoff dongle was disconnected.'); process.exit(6); });
  await controller.permitJoin(0);
  lights = controller.getDevices()
    .filter(d => d.type !== 'Coordinator')
    .map(d => ({ieee: d.ieeeAddr, name: d.modelID ? `${d.modelID} …${d.ieeeAddr.slice(-4)}` : d.ieeeAddr, endpoint: d.endpoints.find(ep => ep.supportsInputCluster('lightingColorCtrl'))}))
    .filter(l => l.endpoint);
  for (const light of lights) {
    try { await light.endpoint.command('genOnOff', 'on', {}, {timeout: 2500}); } catch { /* reported by the next send */ }
  }
  emit('ready', {port, lights: lights.map(({ieee, name}) => ({ieee, name}))});
  pump();
  readStates();
}

const input = readline.createInterface({input: process.stdin});
input.on('line', line => {
  let message;
  try { message = JSON.parse(line); } catch { trace(`unparsed: ${line}`); return; }
  if (message.cmd !== 'color' || ++received % 20 === 1) trace(`recv #${received} ${line}`);
  if (message.cmd === 'color' || message.cmd === 'white') {
    if (message.exactLevel) remember(message);
    pending = message;
    if (controller && lights.length) pump();
  }
  else if (message.cmd === 'trace') trace(`app: ${message.line}`);
  else if (message.cmd === 'snapshot') snapshot();
  else if (message.cmd === 'restore') restore();
  else if (message.cmd === 'quit') shutdown();
});
// The app owns this process: if it goes away, release the serial port instead of lingering.
input.on('close', () => shutdown());
process.on('SIGTERM', () => shutdown());
process.on('SIGINT', () => shutdown());

main().catch(error => { fail(error.message); shutdown(1); });
