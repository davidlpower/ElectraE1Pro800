-- ============================================================
-- Electra One Mk2 — Pro-800 Project Template (firmware ≥ 4.0)
-- FIXED VERSION for Patch Requests
-- ============================================================

-- ---------- Requirements ----------
assert(controller.isRequired(MODEL_MK2, "4.0.0"), "Mk2 firmware 4.0.0+ required")

-- ---------- App registry ----------
local App = {
  cfg = {
    deviceName          = "Pro-800",
    deviceId            = 1,      -- << set to your preset's Device ID
    channel             = 4,      -- keep in sync with the preset device
    port                = nil,    -- DO NOT hardcode; read from device

    -- SysEx specifics
    -- Header (with F0): F0 00 20 32 00 01 24 <dev> 78 <lsb> <msb>  (11 bytes incl. F0)
    headerLenBytes      = 11,
    minExpectedSysexLen = 16,

    devId               = 0x00,   -- Pro-800 accepts 0x00

    -- Behringer CC toggle convention
    toggleOff           = 0,      -- 0..63 = Off
    toggleOn            = 64,     -- 64..127 = On
  },

  dev   = nil,
  ready = false,

  -- Cache for last requested patch index
  _req_lsb = 0,
  _req_msb = 0,
}

-- ---------- Accessors ----------
local function DEV()     return devices.get(App.cfg.deviceId) end
local function devPort() return DEV() and DEV():getPort() or 0 end

-- ---------- Logging ----------
local LOG_ENABLED = true
local function log(...) if LOG_ENABLED then print(table.concat({...}, " ")) end end

-- ---------- Safe setters ----------
local function setPM(deviceId, ptype, paramNum, midiVal)
  if midiVal < 0 then midiVal = 0 end
  if midiVal > 127 then midiVal = 127 end
  log(string.format("setPM: device=%d type=%d param=%d value=%d", deviceId, ptype, paramNum, midiVal))
  parameterMap.set(deviceId, ptype, paramNum, midiVal)
end


-- ============================================================
-- CC map (grouped by UI)
-- ============================================================
local CC = {
  -- MAIN / Oscillator A
  OSC_A_FREQ  = 8,
  OSC_A_VOL   = 9,
  OSC_A_PW    = 10,

  -- MAIN / Oscillator B
  OSC_B_FREQ  = 11,
  OSC_B_VOL   = 12,
  OSC_B_PW    = 13,
  OSC_B_FINE  = 14,

  -- MAIN / VCA
  AMP_VEL     = 31,
  AE_R        = 22, AE_S = 23, AE_D = 24, AE_A = 25,
  AE_SPEED    = 62,           -- 2-state enum

  -- MAIN / Filter
  CUTOFF      = 74,
  RESO        = 16,
  FILT_ENV    = 17,
  FE_R        = 18, FE_S = 19, FE_D = 20, FE_A = 21,
  FILT_VEL    = 32,
  KEYTRK      = 60,           -- 3-state enum
  FE_SPEED    = 61,           -- 2-state enum

  -- MAIN / Vibrato
  VIB_RATE    = 34,
  VIB_AMT     = 35,

  -- MAIN / Extra
  NOISE       = 37,
  GLIDE       = 30,

  -- WAVEFORMS
  A_SAW       = 48,  A_TRI = 49,  A_SQR = 50,
  B_SAW       = 51,  B_TRI = 52,  B_SQR = 53,
  B_SYNC      = 54,

  -- POLY-MOD
  PM_ENV_AMT  = 38,
  PM_OSCB_AMT = 39,
  MOD_DELAY   = 33,           -- modulation delay
  PM_FREQ     = 55,           -- destination toggles
  PM_FILT     = 56,
  UNISON      = 63,
  DETUNE      = 36,           -- unison detune

  -- LFO-MOD
  LFO_RATE    = 28,
  LFO_AMT     = 29,
  LFO_SHAPE   = 57,           -- 6-step enum
  LFO_SPEED   = 58,           -- 2-state enum
  LFO_TARGETS = 59,           -- bitmask (see set_lfo_targets)

  -- Aftertouch depths (device params)
  AT_VCA      = 41,
  AT_VCF      = 42,

  -- Global / performance (not recalled from SysEx)
  BENDER_TGT  = 66,           -- 4-state enum
  MODW_AMT    = 67,           -- 4-state enum
  MODW_TGT    = 70,
  VOICE_SPREAD= 77,           -- toggle (fw dep)
  KTRK_REF    = 78,
  GLIDE_MODE  = 79,           -- 2-state

  -- Addressing
  BANK_MSB    = 0,            -- CC0 for A..D→0..3
  PROGRAM     = 0,            -- PT_PROGRAM index (not a CC)
}

-- ============================================================
-- Offsets into decoded SysEx payload (grouped)
-- ============================================================
local OFF = {
  VERSION     = 4,

  -- Osc A/B
  FREQ_A      = 5,  VOL_A = 7,  PWA = 9,
  FREQ_B      = 11, VOL_B = 13, PWB = 15, FINE_B = 17,

  -- Filter / envelopes
  CUTOFF      = 19, RESO = 21,
  FILT_ENV    = 23,
  FE_R        = 25, FE_S = 27, FE_D = 29, FE_A = 31,
  AE_R        = 33, AE_S = 35, AE_D = 37, AE_A = 39,

  -- Poly-Mod sources
  PM_ENV      = 41, PM_OSCB = 43,

  -- LFO / dynamics
  LFO_FREQ    = 45, LFO_AMT = 47,
  GLIDE       = 49, AMP_VEL = 51, FILT_VEL = 53,

  -- Waveforms / Poly-Mod destinations
  A_SAW       = 55, A_TRI = 56, A_SQR = 57,
  B_SAW       = 58, B_TRI = 59, B_SQR = 60,
  SYNC        = 61, PM_FREQ = 62, PM_FILT = 63,

  -- LFO controls / routing
  LFO_SHAPE   = 64,
  LFO_RANGE   = 65,       -- 2-state enum
  LFO_TARGET  = 66,       -- bitmask

  -- Misc
  KEYTRK      = 67,
  FE_SHAPE    = 68, FE_SPEED = 69,
  AE_SHAPE    = 70,
  UNISON      = 71,
  PB_TARGET   = 72,
  MODW_AMT    = 73,
  A_FREQ_MODE = 74, B_FREQ_MODE = 75,

  -- Vibrato / detune / delay
  MOD_DELAY   = 76,
  VIB_SPEED   = 78, VIB_AMT = 80,
  DETUNE      = 82,

  -- Optional / fw dependent region
  NOISE       = 142,
  VCA_AT      = 144,
  VCF_AT      = 146,
  AE_SPEED    = 148,

  VOICE_SPREAD= 168,
  KTRK_REF    = 169,
  GLIDE_MODE  = 170,
  PB_RANGE    = 171,       -- kept for future use (no CC assigned)
}

-- ============================================================
-- Helpers
-- ============================================================
-- Pair -> CC scaler (keeps your logging & flexibility)
-- width_bits: 14 (7+7) or 16 (8+8) after unpack7to8_into()
local function set_cc_pair(cc, lo, hi, width_bits, label)
  if lo == nil or hi == nil then return end
  lo = lo & 0xFF; hi = hi & 0xFF

  local v
  if width_bits == 14 then            -- legacy path (rare)
    v = ((hi & 0x7F) << 7) | (lo & 0x7F)         -- 0..16383
  else                                -- default: true 16-bit
    v = (hi << 8) | lo                           -- 0..65535
  end

  -- scale to 0..127 with rounding
  local denom = (width_bits == 14) and 16383 or 65535
  local midi  = math.floor((v * 127) / denom + 0.5)
  if midi < 0 then midi = 0 elseif midi > 127 then midi = 127 end

  -- targeted debug logging
  if cc == CC.RESO or cc == CC.FE_A or cc == CC.FE_D or cc == CC.FE_S or cc == CC.FE_R or
     cc == CC.AE_A or cc == CC.AE_D or cc == CC.AE_S or cc == CC.AE_R then
    log(string.format("pair->cc(%s): CC=%d lo=%02X hi=%02X v=%d/%d -> %d",
      label or "", cc, lo, hi, v, denom, midi))
  end

  setPM(App.cfg.deviceId, PT_CC7, cc, midi)
end

-- Convenience aliases so call sites stay readable
local function set_cc_u16(cc, lo, hi, label) return set_cc_pair(cc, lo, hi, 16, label) end
local function set_cc_u14(cc, lo, hi, label) return set_cc_pair(cc, lo, hi, 14, label) end

-- Unpack Electra 7bit-packed block into 8-bit bytes
local function unpack7to8_into(dst, syx, start_index, end_index_exclusive)
  local i = start_index
  while i < end_index_exclusive do
    local map = syx:peek(i); if map == nil then log("unpack7to8: nil at ", i); break end
    i = i + 1
    for k = 0, 6 do
      if i >= end_index_exclusive then break end
      local b = syx:peek(i); if b == nil then log("unpack7to8: nil at ", i, " in block"); break end
      i = i + 1
      local msb = (map >> k) & 0x01
      dst[#dst+1] = ((msb & 0x01) << 7) | (b & 0x7F)
    end
  end
end

-- ============================================================
-- Device init / lifecycle
-- ============================================================
local function initDevice()
  App.dev = DEV()
  assert(App.dev, "Device ID "..tostring(App.cfg.deviceId).." not found")
  App.cfg.port    = App.dev:getPort()
  App.cfg.channel = App.dev:getChannel()
  log(("Device OK: id=%d port=%d ch=%d"):format(App.dev:getId(), App.cfg.port, App.cfg.channel))
end

function preset.onLoad()
  log("Preset loading… Mk2 FW:", controller.getFirmwareVersion())
  initDevice()
end

function preset.onReady()
  App.ready = true
  info.setText("Pro-800 ready - Try PATCH REQUEST")
  log("Ready. Use PATCH REQUEST button.")
end

function preset.onExit()
  App.ready = false
  log("Preset exiting")
end

-- ============================================================
-- SysEx decode and application
-- ============================================================
local function applyDump(sysexBlock)
  local n = sysexBlock:getLength()
  if n < App.cfg.minExpectedSysexLen then log("Sysex too short: len=", n); return end

  -- Electra uses 1-based indexing for peek
  local has_f0 = (sysexBlock:peek(1) == 0xF0)
  local p0     = has_f0 and 12 or 11   -- start of packed data (after header)
  local end_i  = has_f0 and (n - 1) or n  -- exclude trailing F7 if present

  log(string.format("applyDump: has_f0=%s, decode start=%d, end=%d", tostring(has_f0), p0, end_i))

  -- Build decoded buffer
  local decoded = {}
  unpack7to8_into(decoded, sysexBlock, p0, end_i)
  log(string.format("Decoded %d bytes from SysEx", #decoded))

  -- Osc A/B (16-bit pairs)
  set_cc_u16(CC.OSC_A_FREQ, decoded[OFF.FREQ_A] or 0, decoded[OFF.FREQ_A+1] or 0, "OSC_A_FREQ")
  set_cc_u16(CC.OSC_A_VOL,  decoded[OFF.VOL_A]  or 0, decoded[OFF.VOL_A+1]  or 0, "OSC_A_VOL")
  set_cc_u16(CC.OSC_A_PW,   decoded[OFF.PWA]    or 0, decoded[OFF.PWA+1]    or 0, "OSC_A_PW")
  set_cc_u16(CC.OSC_B_FREQ, decoded[OFF.FREQ_B] or 0, decoded[OFF.FREQ_B+1] or 0, "OSC_B_FREQ")
  set_cc_u16(CC.OSC_B_VOL,  decoded[OFF.VOL_B]  or 0, decoded[OFF.VOL_B+1]  or 0, "OSC_B_VOL")
  set_cc_u16(CC.OSC_B_PW,   decoded[OFF.PWB]    or 0, decoded[OFF.PWB+1]    or 0, "OSC_B_PW")
  set_cc_u16(CC.OSC_B_FINE, decoded[OFF.FINE_B] or 0, decoded[OFF.FINE_B+1] or 0, "OSC_B_FINE")

  -- Filter / envelopes (16-bit pairs)
  set_cc_u16(CC.CUTOFF,      decoded[OFF.CUTOFF]   or 0, decoded[OFF.CUTOFF+1]   or 0, "CUTOFF")
  set_cc_u16(CC.RESO,        decoded[OFF.RESO]     or 0, decoded[OFF.RESO+1]     or 0, "RESO")
  set_cc_u16(CC.FILT_ENV,    decoded[OFF.FILT_ENV] or 0, decoded[OFF.FILT_ENV+1] or 0, "FILT_ENV")
  set_cc_u16(CC.FE_R,        decoded[OFF.FE_R]     or 0, decoded[OFF.FE_R+1]     or 0, "FE_R")
  set_cc_u16(CC.FE_S,        decoded[OFF.FE_S]     or 0, decoded[OFF.FE_S+1]     or 0, "FE_S")
  set_cc_u16(CC.FE_D,        decoded[OFF.FE_D]     or 0, decoded[OFF.FE_D+1]     or 0, "FE_D")
  set_cc_u16(CC.FE_A,        decoded[OFF.FE_A]     or 0, decoded[OFF.FE_A+1]     or 0, "FE_A")
  set_cc_u16(CC.AE_R,        decoded[OFF.AE_R]     or 0, decoded[OFF.AE_R+1]     or 0, "AE_R")
  set_cc_u16(CC.AE_S,        decoded[OFF.AE_S]     or 0, decoded[OFF.AE_S+1]     or 0, "AE_S")
  set_cc_u16(CC.AE_D,        decoded[OFF.AE_D]     or 0, decoded[OFF.AE_D+1]     or 0, "AE_D")
  set_cc_u16(CC.AE_A,        decoded[OFF.AE_A]     or 0, decoded[OFF.AE_A+1]     or 0, "AE_A")

  -- LFO / dynamics (16-bit pairs)
  set_cc_u16(CC.LFO_RATE,    decoded[OFF.LFO_FREQ] or 0, decoded[OFF.LFO_FREQ+1] or 0, "LFO_RATE")
  set_cc_u16(CC.LFO_AMT,     decoded[OFF.LFO_AMT]  or 0, decoded[OFF.LFO_AMT+1]  or 0, "LFO_AMT")
  set_cc_u16(CC.GLIDE,       decoded[OFF.GLIDE]    or 0, decoded[OFF.GLIDE+1]    or 0, "GLIDE")
  set_cc_u16(CC.AMP_VEL,     decoded[OFF.AMP_VEL]  or 0, decoded[OFF.AMP_VEL+1]  or 0, "AMP_VEL")
  set_cc_u16(CC.FILT_VEL,    decoded[OFF.FILT_VEL] or 0, decoded[OFF.FILT_VEL+1] or 0, "FILT_VEL")

  -- Vibrato / delay / detune (16-bit pairs)
  set_cc_u16(CC.MOD_DELAY,   decoded[OFF.MOD_DELAY] or 0, decoded[OFF.MOD_DELAY+1] or 0, "MOD_DELAY")
  set_cc_u16(CC.VIB_RATE,    decoded[OFF.VIB_SPEED] or 0, decoded[OFF.VIB_SPEED+1] or 0, "VIB_RATE")
  set_cc_u16(CC.VIB_AMT,     decoded[OFF.VIB_AMT]   or 0, decoded[OFF.VIB_AMT+1]   or 0, "VIB_AMT")
  set_cc_u16(CC.DETUNE,      decoded[OFF.DETUNE]    or 0, decoded[OFF.DETUNE+1]    or 0, "DETUNE")

  -- Waveforms / Poly-Mod destinations (toggles)
  set_toggle(CC.A_SAW,       decoded[OFF.A_SAW] or 0)
  set_toggle(CC.A_TRI,       decoded[OFF.A_TRI] or 0)
  set_toggle(CC.A_SQR,       decoded[OFF.A_SQR] or 0)
  set_toggle(CC.B_SAW,       decoded[OFF.B_SAW] or 0)
  set_toggle(CC.B_TRI,       decoded[OFF.B_TRI] or 0)
  set_toggle(CC.B_SQR,       decoded[OFF.B_SQR] or 0)
  set_toggle(CC.B_SYNC,      decoded[OFF.SYNC]  or 0)
  set_toggle(CC.PM_FREQ,     decoded[OFF.PM_FREQ] or 0)
  set_toggle(CC.PM_FILT,     decoded[OFF.PM_FILT] or 0)
  set_toggle(CC.UNISON,      decoded[OFF.UNISON] or 0)

  -- Enums / lists
  set_lfo_shape(CC.LFO_SHAPE,   decoded[OFF.LFO_SHAPE] or 0)  -- 0..5 → spaced in 0..127
  set_enum_linear(CC.LFO_SPEED,  decoded[OFF.LFO_RANGE] or 0, 2)
  set_enum_linear(CC.KEYTRK,     decoded[OFF.KEYTRK]    or 0, 3)
  set_enum_linear(CC.FE_SPEED,    decoded[OFF.FE_SPEED]  or 0, 2)
  set_enum_linear(CC.AE_SPEED,    decoded[OFF.AE_SPEED]  or 0, 2)
  set_enum_linear(CC.BENDER_TGT, decoded[OFF.PB_TARGET] or 0, 4)
  set_enum_linear(CC.MODW_AMT,   decoded[OFF.MODW_AMT]  or 0, 4)
  set_enum_linear(CC.GLIDE_MODE, decoded[OFF.GLIDE_MODE] or 0, 2)

  -- LFO targets bitmask → raw CC value (0..127)
  if CC.LFO_TARGETS then set_lfo_targets(CC.LFO_TARGETS, decoded[OFF.LFO_TARGET] or 0) end

  -- Optional / firmware-dependent fields
  if decoded[OFF.VOICE_SPREAD] ~= nil then set_toggle(CC.VOICE_SPREAD, decoded[OFF.VOICE_SPREAD] or 0) end

  -- Additional continuous fields (16-bit pairs)
  set_cc_u16(CC.NOISE,       decoded[OFF.NOISE]   or 0, decoded[OFF.NOISE+1]   or 0, "NOISE")
  set_cc_u16(CC.PM_ENV_AMT,  decoded[OFF.PM_ENV]  or 0, decoded[OFF.PM_ENV+1]  or 0, "PM_ENV_AMT")
  set_cc_u16(CC.PM_OSCB_AMT, decoded[OFF.PM_OSCB] or 0, decoded[OFF.PM_OSCB+1] or 0, "PM_OSCB_AMT")
  set_cc_u16(CC.AT_VCA,      decoded[OFF.VCA_AT]  or 0, decoded[OFF.VCA_AT+1]  or 0, "AT_VCA")
  set_cc_u16(CC.AT_VCF,      decoded[OFF.VCF_AT]  or 0, decoded[OFF.VCF_AT+1]  or 0, "AT_VCF")
  -- PB_RANGE present at OFF.PB_RANGE but no CC assigned here.

  info.setText("Patch loaded successfully!")
  log("applyDump complete: processed", #decoded, "bytes")
end

-- ============================================================
-- Patch request / response
-- ============================================================
function patch.onRequest(device)
  if device.id ~= App.cfg.deviceId then
    log("patch.onRequest: wrong device id", device.id, "expected", App.cfg.deviceId)
    return
  end

  log("patch.onRequest: Starting patch request")

  -- Read current bank/program from Parameter Map
  local bank = parameterMap.get(App.cfg.deviceId, PT_CC7,     CC.BANK_MSB) or 0
  local prog = parameterMap.get(App.cfg.deviceId, PT_PROGRAM, CC.PROGRAM)  or 0

  -- Linear index 0..399 → 7-bit LSB/MSB
  local index = bank * 100 + prog
  if index < 0 then index = 0 end
  if index > 399 then index = 399 end
  local lsb   = index % 128
  local msb   = (index - lsb) / 128

  -- Store for response matcher
  App._req_lsb = lsb & 0x7F
  App._req_msb = msb & 0x7F

  log(string.format("Requesting patch: bank=%d prog=%d index=%d (lsb=%02X msb=%02X)", bank, prog, index, lsb, msb))

  -- Send Pro-800 patch request: 00 20 32 00 01 24 <dev> 77 <lsb> <msb>
  midi.sendSysex(devPort(), {
    0x00,0x20,0x32,0x00,0x01,0x24, App.cfg.devId & 0x7F,
    0x77, lsb & 0x7F, msb & 0x7F
  })

  info.setText("Patch request sent...")
  log("MIDI SysEx sent - waiting for response")
end

function patch.onResponse(device, responseId, sysexBlock)
  if device.id ~= App.cfg.deviceId then
    log("patch.onResponse: wrong device id", device.id, "expected", App.cfg.deviceId)
    return
  end

  local n = sysexBlock:getLength()
  log("patch.onResponse: received sysex, length=", n)

  if n <= App.cfg.headerLenBytes then
    log("patch.onResponse: sysex too short, ignoring"); return
  end

  log("patch.onResponse: processing dump")
  applyDump(sysexBlock)
end

-- ============================================================
-- MIDI input monitoring
-- ============================================================
function midi.onControlChange(mi, ch, cc, val)
  if ch ~= App.cfg.channel then return end
  log(string.format("CC%d = %d (ch %d)", cc, val, ch))
end

function midi.onSysex(mi, syx)
  log("======SYSEX RECEIVED======")
  local n = syx:getLength()
  local has_f0 = (syx:peek(1) == 0xF0)

  -- header dump for inspection
  local head = {}
  for i = 1, math.min(20, n) do head[#head+1] = string.format("%02X", syx:peek(i) or 0) end
  log(string.format("Sysex length=%d", n))
  log(string.format("Header bytes: %s", table.concat(head, " ")))

  -- Pro-800 dump header after optional F0:
  -- 00 20 32 00 01 24 <dev> 78 <lsb> <msb>
  local base = has_f0 and 2 or 1
  local ok = (n > (base+9)
    and syx:peek(base+0)==0x00 and syx:peek(base+1)==0x20
    and syx:peek(base+2)==0x32 and syx:peek(base+3)==0x00
    and syx:peek(base+4)==0x01 and syx:peek(base+5)==0x24
    and syx:peek(base+7)==0x78)

  if ok then
    local dev = syx:peek(base+6)
    local lsb = (syx:peek(base+8) or 0) & 0x7F
    local msb = (syx:peek(base+9) or 0) & 0x7F
    log(string.format("Pro-800 patch dump detected: dev=%02X lsb=%02X msb=%02X", dev or 0, lsb, msb))

    if lsb == App._req_lsb and msb == App._req_msb then
      log("Patch matches our request - processing")
      applyDump(syx)
    else
      log(string.format("Patch mismatch: got %02X:%02X, expected %02X:%02X", lsb, msb, App._req_lsb, App._req_msb))
    end
  else
    log(string.format("Not a Pro-800 patch dump; byte at '78' pos = %02X", syx:peek(base+7) or 0xFF))
  end

  log("======SYSEX END======")
end

-- ============================================================
-- Utilities
-- ============================================================
local function pingP800()
  midi.sendSysex(devPort(), {
    0x00,0x20,0x32,0x00,0x01,0x24, App.cfg.devId & 0x7F,
    0x77, 0x7E, 0x03   -- System Settings request (short reply)
  })
  info.setText("Sent: 77 7E 03")
  log("Ping sent to Pro-800")
end

local function doResync()
  info.setText("Requesting all patches...")
  patch.requestAll()
  log("Manual resync requested")
end

local function midiPanic()
  for ch=1,16 do
    for n=0,127 do midi.sendNoteOff(devPort(), ch, n, 0) end
  end
  info.setText("MIDI panic sent")
  log("MIDI panic executed")
end

local function doPing()
  pingP800()
end

-- Assign user functions (Electra exposes pot1..pot12)
preset.userFunctions = {
  pot10 = { call = doPing,    name = "Ping",   close = true },
  pot11 = { call = doResync,  name = "Resync", close = true },
  pot12 = { call = midiPanic, name = "Panic",  close = true },
}
