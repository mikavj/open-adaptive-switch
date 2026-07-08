// =========================================================================
// Open Adaptive Switch - consolidated firmware (v3)
// Target: Seeed XIAO nRF52840 (plain or Sense variant)
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors
//
// One firmware for every unit. The old per-unit builds (A = single key,
// B = tap/hold, C = three press-duration zones) are now runtime modes,
// and the key bindings, mode, device name, LED color, and sleep timeout
// are all set from a phone or computer through a BLE configuration
// service (see docs/ble-protocol.md and the config page in docs/).
// Settings persist in internal flash and survive reboots and firmware
// updates.
//
// Services exposed:
//   - HID keyboard (the switch itself)
//   - Battery Service 0x180F (shows in the iOS Batteries widget)
//   - Device Information 0x180A (firmware version, model)
//   - Nordic DFU (over-the-air firmware updates via the bootloader;
//     use Nordic's "nRF Device Firmware Update" app with the release
//     .zip - see SETUP.md)
//   - Custom config service F6BA8E00-... (this file, docs/ble-protocol.md)
//
// Battery notes (see README.md for the full story):
//   - Charging is controlled entirely by the onboard BQ25101 charger IC:
//     4.20V termination, fixed in hardware. A cell that reads ~4.15-4.2V
//     after a charge is full, not overcharged.
//   - Charge current stays at the 50mA default (P0.13 left high-Z), the
//     gentlest option for the 250mAh cell. Define CHARGE_AT_100MA to
//     charge bigger cells faster.
//   - The battery divider enable pin P0.14 is held LOW continuously
//     (the core's initVariant() parks it HIGH at boot, so setup() flips
//     it first thing). Constant LOW costs 2.8uA and keeps P0.31 safely
//     divided; HIGH puts P0.31 near its 3.6V absolute maximum (Seeed
//     wiki warning). Earlier firmware versions addressed these pins by
//     raw port number, which this core ignores, so v1/v2 battery
//     readings never actually worked - they always returned 0V.
//   - No firmware low-voltage shutdown. v2.0 had one and it false-
//     triggered on BLE TX sag. Low battery is reported by LED and over
//     BLE; the percentage table bottoms out at 3.5V, well above damage
//     territory.
// =========================================================================

#include <bluefruit.h>
#include <Adafruit_LittleFS.h>
#include <InternalFileSystem.h>

using namespace Adafruit_LittleFS_Namespace;

#define FW_VERSION "3.1.0"

// =========================================================================
// ====================== SETTINGS YOU MIGHT CHANGE ========================
// =========================================================================
// Almost everything users care about is now runtime-configurable over
// BLE. What remains here are hardware choices and defaults.

// Default BLE name, used until the user renames the switch from the app
// or config page. Keep names 15 chars or fewer: the advertising packet is
// 31 bytes, and flags + appearance + HID UUID leave room for a 15-char
// complete name.
const char* DEFAULT_DEVICE_NAME = "Access Switch";

// ---- Button pin ----
// XIAO nRF52840 Sense pin labels D0..D10 are all valid INPUT_PULLUP options.
const uint8_t PIN_BUTTON = D0;

// ---- Charge current ----
// Leave undefined for the 50mA default (P0.13 high-Z, the clean state per
// the TI datasheet). Define to charge at 100mA - only for cells of 300mAh
// or more.
// #define CHARGE_AT_100MA

// ---- Press duration thresholds (ms) ----
// Mode 1 (tap/hold): below HOLD_MS is a tap, at or above is a hold.
// Mode 2 (zones):    short < HOLD_MS <= medium < LONG_MS <= long.
const uint32_t HOLD_MS = 500;
const uint32_t LONG_MS = 2000;

// ---- External bi-color charge-status LED (optional) --------------------
// Panel-mount 3mm COMMON-CATHODE red/green LED that shows charge status
// where the onboard LED can't be seen (e.g. inside an enclosure). Wiring:
//
//   D9  --[ 470R ]-->  RED anode      (charging)
//   D10 --[ 470R ]-->  GREEN anode    (charged / full)
//   GND ------------>  common cathode (shared)
//
// COMMON-CATHODE, so GPIO HIGH turns a color ON - the OPPOSITE polarity
// of the onboard common-anode LED (LOW = ON). One resistor per anode leg.
// Safe to leave enabled with nothing wired; comment out to free D9/D10.
#define ENABLE_EXT_CHARGE_LED
const uint8_t EXT_LED_RED   = D9;
const uint8_t EXT_LED_GREEN = D10;

// =========================================================================
// ==================== END SETTINGS - code below ==========================
// =========================================================================

// XIAO nRF52840 battery pins, using the named indices from the Seeed
// variant (variant.h). The v1/v2 firmware used raw nRF port numbers here
// (46, 31, 13), which silently miss: digitalWrite past PINS_COUNT is a
// no-op and analogRead(31) lands on the NFC pin, so battery telemetry
// always read 0V and the divider was never enabled. If you port this
// code, check your variant's pin map first.
// P0.17 (charger status) is not in the Arduino pin map, so it is read
// through nrf_gpio directly.
#define PIN_BAT_READ_EN  VBAT_ENABLE           // pin 14 -> P0.14, divider low side
#define PIN_VBAT_ADC     PIN_VBAT              // pin 32 -> P0.31 (AIN7), divider tap
#define PIN_CHARGE_SEL   PIN_CHARGING_CURRENT  // pin 22 -> P0.13, high-Z = 50mA, LOW = 100mA
#define NRF_PIN_CHG      17                    // P0.17: BQ25101 /CHG, LOW = charging

const uint32_t DEBOUNCE_MS         = 30;
const uint32_t LED_PULSE_PERIOD_MS = 1500;
const uint32_t BAT_SAMPLE_MS       = 30000;  // voltage sample cadence
const uint8_t  BAT_BURST_READS     = 8;      // ADC reads averaged per sample
const float    BAT_LOW_V           = 3.55;   // solid red status LED
const float    BAT_CRITICAL_V      = 3.35;   // blinking red status LED

// ---- Persisted configuration -------------------------------------------
// Written to internal flash (LittleFS) on every change; survives reboot
// and OTA updates. Layout matches docs/ble-protocol.md.

#define CONFIG_FILE   "/oas.cfg"
#define CONFIG_TMP    "/oas.tmp"
#define CONFIG_MAGIC  0x3353414FUL   // "OAS3" little-endian
// Bump when the default settings change so existing boards adopt them on
// the next flash. v2: default name changed to "Access Switch".
#define CONFIG_STRUCT_VERSION 2

// Modes: what a button press sends.
enum : uint8_t {
  MODE_SINGLE   = 0,  // press sends key slot 0 (old Unit A)
  MODE_TAP_HOLD = 1,  // tap sends slot 0, hold sends slot 1 (old Unit B)
  MODE_ZONES    = 2,  // short/medium/long send slots 0/1/2 (old Unit C)
};

enum : uint8_t { ACCENT_RED = 0, ACCENT_GREEN = 1, ACCENT_BLUE = 2 };

typedef struct __attribute__((packed)) {
  uint32_t magic;
  uint8_t  structVersion;
  uint8_t  mode;
  uint8_t  accent;
  uint8_t  reserved;
  uint8_t  keymap[6];       // slot 0..2 as [modifier, keycode] pairs
  uint16_t sleepMinutes;    // 0 = never sleep
  char     name[16];        // NUL-terminated BLE name, 15 chars max
} Config;

Config cfg;

void configDefaults() {
  memset(&cfg, 0, sizeof(cfg));
  cfg.magic         = CONFIG_MAGIC;
  cfg.structVersion = CONFIG_STRUCT_VERSION;
  cfg.mode          = MODE_SINGLE;
  cfg.accent        = ACCENT_RED;
  cfg.keymap[0] = 0; cfg.keymap[1] = HID_KEY_F13;  // slot 0: tap/short
  cfg.keymap[2] = 0; cfg.keymap[3] = HID_KEY_F14;  // slot 1: hold/medium
  cfg.keymap[4] = 0; cfg.keymap[5] = HID_KEY_F15;  // slot 2: long
  cfg.sleepMinutes  = 30;
  strcpy(cfg.name, DEFAULT_DEVICE_NAME);
}

void configLoad() {
  configDefaults();
  File f(InternalFS);
  if (f.open(CONFIG_FILE, FILE_O_READ)) {
    Config onDisk;
    uint32_t n = f.read((uint8_t*)&onDisk, sizeof(onDisk));
    f.close();
    if (n == sizeof(onDisk)
        && onDisk.magic == CONFIG_MAGIC
        && onDisk.structVersion == CONFIG_STRUCT_VERSION) {
      cfg = onDisk;
      cfg.name[15] = 0;   // belt and suspenders
    }
  }
}

void configSave() {
  // Write a temp file, then rename over the real one. littlefs rename
  // replaces the destination atomically, so a power cut mid-save leaves
  // the previous config intact instead of none. (FILE_O_WRITE appends
  // to an existing file, hence removing any stale temp first.) Config
  // writes are rare (user actions), so flash wear is not a concern.
  InternalFS.remove(CONFIG_TMP);
  File f(InternalFS);
  if (f.open(CONFIG_TMP, FILE_O_WRITE)) {
    f.write((uint8_t*)&cfg, sizeof(cfg));
    f.close();
    InternalFS.rename(CONFIG_TMP, CONFIG_FILE);
  }
}

// ---- BLE services -------------------------------------------------------

BLEDfu  bledfu;   // OTA DFU into the bootloader; must begin() first
BLEDis  bledis;
BLEBas  blebas;
BLEHidAdafruit blehid;

// Custom config service. Base F6BA8Exx-4094-4E31-B42A-5AAEF6FC5C7D;
// full layout in docs/ble-protocol.md.
const uint8_t UUID_SVC_CONFIG[16] =
  {0x7D,0x5C,0xFC,0xF6,0xAE,0x5A,0x2A,0xB4,0x31,0x4E,0x94,0x40,0x00,0x8E,0xBA,0xF6};
const uint8_t UUID_CHR_MODE[16] =
  {0x7D,0x5C,0xFC,0xF6,0xAE,0x5A,0x2A,0xB4,0x31,0x4E,0x94,0x40,0x01,0x8E,0xBA,0xF6};
const uint8_t UUID_CHR_KEYMAP[16] =
  {0x7D,0x5C,0xFC,0xF6,0xAE,0x5A,0x2A,0xB4,0x31,0x4E,0x94,0x40,0x02,0x8E,0xBA,0xF6};
const uint8_t UUID_CHR_SLEEP[16] =
  {0x7D,0x5C,0xFC,0xF6,0xAE,0x5A,0x2A,0xB4,0x31,0x4E,0x94,0x40,0x03,0x8E,0xBA,0xF6};
const uint8_t UUID_CHR_NAME[16] =
  {0x7D,0x5C,0xFC,0xF6,0xAE,0x5A,0x2A,0xB4,0x31,0x4E,0x94,0x40,0x04,0x8E,0xBA,0xF6};
const uint8_t UUID_CHR_BATTERY[16] =
  {0x7D,0x5C,0xFC,0xF6,0xAE,0x5A,0x2A,0xB4,0x31,0x4E,0x94,0x40,0x05,0x8E,0xBA,0xF6};
const uint8_t UUID_CHR_COMMAND[16] =
  {0x7D,0x5C,0xFC,0xF6,0xAE,0x5A,0x2A,0xB4,0x31,0x4E,0x94,0x40,0x06,0x8E,0xBA,0xF6};
const uint8_t UUID_CHR_ACCENT[16] =
  {0x7D,0x5C,0xFC,0xF6,0xAE,0x5A,0x2A,0xB4,0x31,0x4E,0x94,0x40,0x07,0x8E,0xBA,0xF6};

BLEService        svcConfig(UUID_SVC_CONFIG);
BLECharacteristic chrMode(UUID_CHR_MODE);
BLECharacteristic chrKeymap(UUID_CHR_KEYMAP);
BLECharacteristic chrSleep(UUID_CHR_SLEEP);
BLECharacteristic chrName(UUID_CHR_NAME);
BLECharacteristic chrBattery(UUID_CHR_BATTERY);
BLECharacteristic chrCommand(UUID_CHR_COMMAND);
BLECharacteristic chrAccent(UUID_CHR_ACCENT);

// Commands accepted on chrCommand (docs/ble-protocol.md):
enum : uint8_t {
  CMD_REBOOT        = 1,  // apply a pending rename
  CMD_FACTORY_RESET = 2,  // defaults + reboot
  CMD_ENTER_DFU     = 3,  // reboot into the OTA bootloader
};

// Battery state byte in chrBattery:
enum : uint8_t {
  BATT_DISCHARGING = 0,
  BATT_CHARGING    = 1,
  BATT_FULL_USB    = 2,   // USB present, charger terminated
};

// ---- Runtime state ------------------------------------------------------

uint32_t lastActivityMs   = 0;
uint32_t lastBatSampleMs  = 0;
float    batteryV         = 4.0;    // EMA-filtered volts
uint8_t  reportedPercent  = 255;    // last value pushed over BLE
uint8_t  batteryState     = BATT_DISCHARGING;
uint8_t  socRatchet       = 100;    // monotonic percent while discharging
bool     buttonPrev       = HIGH;
uint32_t buttonChangeMs   = 0;
uint32_t buttonDownAtMs   = 0;
uint32_t amberConfirmUntilMs = 0;
volatile uint8_t pendingCommand = 0;

// =========================================================================
// LED helpers - onboard RGB is common-anode (LOW = ON)
// =========================================================================
void ledRedOn()    { digitalWrite(LED_RED,   LOW);  }
void ledRedOff()   { digitalWrite(LED_RED,   HIGH); }
void ledGreenOn()  { digitalWrite(LED_GREEN, LOW);  }
void ledGreenOff() { digitalWrite(LED_GREEN, HIGH); }
void ledBlueOn()   { digitalWrite(LED_BLUE,  LOW);  }
void ledBlueOff()  { digitalWrite(LED_BLUE,  HIGH); }
void ledAllOff()   { ledRedOff(); ledGreenOff(); ledBlueOff(); }
void ledAmberOn()  { ledRedOn();  ledGreenOn(); }
void ledPurpleOn() { ledRedOn();  ledBlueOn(); ledGreenOff(); }

// Accent color comes from config now, not a compile-time define.
void ledAccentOn() {
  switch (cfg.accent) {
    case ACCENT_GREEN: ledGreenOn(); break;
    case ACCENT_BLUE:  ledBlueOn();  break;
    default:           ledRedOn();   break;
  }
}
void ledAccentOff() {
  switch (cfg.accent) {
    case ACCENT_GREEN: ledGreenOff(); break;
    case ACCENT_BLUE:  ledBlueOff();  break;
    default:           ledRedOff();   break;
  }
}

// =========================================================================
// Battery measurement and state
// =========================================================================

// Raw voltage: burst-average the ADC, scale through the 1M/510k divider.
// P0.14 is already held LOW (divider always enabled, 2.8uA).
float readBatteryVoltageOnce() {
  uint32_t total = 0;
  for (uint8_t i = 0; i < BAT_BURST_READS; i++) {
    total += analogRead(PIN_VBAT_ADC);
    delay(2);
  }
  float raw  = (float)total / BAT_BURST_READS;
  float vPin = raw * (3.0f / 4096.0f);
  return vPin * (1510.0f / 510.0f);
}

// USB present? Reads the nRF52840 hardware VBUS-detect bit; true whenever
// 5V is on the connector, no host needed.
bool usbPowered() {
  return (NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk) != 0;
}

// Actively charging? BQ25101 /CHG on P0.17 is open-drain, pulled up by
// the CHG LED network: LOW = charging. HIGH alone is ambiguous (done OR
// unplugged), so callers combine it with usbPowered().
bool chargerActive() {
  return nrf_gpio_pin_read(NRF_PIN_CHG) == 0;
}

// Resting-voltage state of charge, 11-point table with interpolation.
// Values are resting OCV for a 1S LiPo under the switch's roughly 1mA
// load (which sags the cell only a few mV, so measured voltage is
// effectively resting). Bottom of the table is 3.5V: the cell is not
// damaged there, but it is nearly empty and the user should charge.
// Endpoints follow the ZMK and Adafruit discharge references; see
// README.md, Battery section.
uint8_t voltageToPercent(uint16_t mv) {
  static const uint16_t soc_mv[11] = {
    4200, 4110, 4020, 3950, 3870, 3840, 3800, 3770, 3730, 3690, 3500
  };
  if (mv >= soc_mv[0])  return 100;
  if (mv <= soc_mv[10]) return 0;
  for (uint8_t i = 1; i < 11; i++) {
    if (mv > soc_mv[i]) {
      // Between point i (lower %) and point i-1 (higher %).
      uint8_t pctHigh = 100 - (i - 1) * 10;
      return pctHigh - 10
           + (uint8_t)(10UL * (mv - soc_mv[i]) / (soc_mv[i - 1] - soc_mv[i]));
    }
  }
  return 0;
}

// Sample, filter, derive state, and push over BLE when something changed.
//
// Reporting rules (see README.md, Battery section):
//   - While discharging the reported percent only ever falls (a ratchet),
//     so BLE TX voltage rebound can't make the number bounce upward.
//   - While charging the voltage reads high and no formula fixes that, so
//     the percent is capped at 99 until the charger IC itself terminates.
//   - Charger terminated with USB still present = 100.
void batterySample() {
  float v = readBatteryVoltageOnce();
  batteryV += (v - batteryV) * 0.5f;   // EMA smoothing
  uint16_t mv = (uint16_t)(batteryV * 1000.0f);

  uint8_t pct;
  if (chargerActive()) {
    batteryState = BATT_CHARGING;
    pct = voltageToPercent(mv);
    if (pct > 99) pct = 99;
    socRatchet = pct;                  // re-arm the ratchet at this level
  } else if (usbPowered()) {
    batteryState = BATT_FULL_USB;
    pct = 100;
    socRatchet = 100;
  } else {
    batteryState = BATT_DISCHARGING;
    pct = voltageToPercent(mv);
    if (pct > socRatchet) pct = socRatchet;   // never rises on battery
    socRatchet = pct;
  }

  // Push to every connected link. The parameterless notify() targets
  // only the most recent connection, which starves whichever of the two
  // links (HID host, config page) connected first.
  if (pct != reportedPercent) {
    reportedPercent = pct;
    blebas.write(pct);
    for (uint16_t c = 0; c < 2; c++) {
      if (Bluefruit.connected(c)) blebas.notify(c, pct);
    }
  }
  uint8_t payload[4] = {
    (uint8_t)(mv & 0xFF), (uint8_t)(mv >> 8), pct, batteryState
  };
  chrBattery.write(payload, sizeof(payload));
  for (uint16_t c = 0; c < 2; c++) {
    if (Bluefruit.connected(c) && chrBattery.notifyEnabled(c)) {
      chrBattery.notify(c, payload, sizeof(payload));
    }
  }

  // Also advertise the battery so scanners can show it before connecting.
  refreshAdvBattery(pct, batteryState);
}

// =========================================================================
// External charge LED (common-cathode: HIGH = ON)
// =========================================================================
#ifdef ENABLE_EXT_CHARGE_LED
void extOff() { digitalWrite(EXT_LED_RED, LOW); digitalWrite(EXT_LED_GREEN, LOW); }

// charging -> solid red; charged (USB, terminated) -> solid green;
// on battery and critical -> blinking red; otherwise off to save the cell.
void updateChargeLed(uint32_t now) {
  if (batteryState == BATT_CHARGING) {
    digitalWrite(EXT_LED_RED, HIGH); digitalWrite(EXT_LED_GREEN, LOW);
  } else if (batteryState == BATT_FULL_USB) {
    digitalWrite(EXT_LED_RED, LOW);  digitalWrite(EXT_LED_GREEN, HIGH);
  } else if (batteryV < BAT_CRITICAL_V) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    digitalWrite(EXT_LED_RED, on ? HIGH : LOW);
    digitalWrite(EXT_LED_GREEN, LOW);
  } else {
    extOff();
  }
}
#endif

// =========================================================================
// HID output
// =========================================================================

// Send one configured slot: press with modifier, brief hold, release.
void sendSlot(uint8_t slot) {
  uint8_t modifier = cfg.keymap[slot * 2];
  uint8_t keycode  = cfg.keymap[slot * 2 + 1];
  if (keycode == 0 && modifier == 0) return;   // slot disabled
  uint8_t keys[6] = { keycode, 0, 0, 0, 0, 0 };
  blehid.keyboardReport(modifier, keys);
  delay(15);
  blehid.keyRelease();
}

// =========================================================================
// Config service plumbing
// =========================================================================

// Push current config values into the readable characteristics so a
// connected page always reads the live state.
void configPublish() {
  chrMode.write8(cfg.mode);
  chrKeymap.write(cfg.keymap, 6);
  chrSleep.write16(cfg.sleepMinutes);
  chrName.write(cfg.name, strlen(cfg.name));
  chrAccent.write8(cfg.accent);
}

void onWriteMode(uint16_t conn, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void)conn; (void)chr;
  if (len == 1 && data[0] <= MODE_ZONES) {
    cfg.mode = data[0];
    configSave();
  }
  configPublish();
}

void onWriteKeymap(uint16_t conn, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void)conn; (void)chr;
  if (len == 6) {
    memcpy(cfg.keymap, data, 6);
    configSave();
  }
  configPublish();
}

void onWriteSleep(uint16_t conn, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void)conn; (void)chr;
  if (len == 2) {
    cfg.sleepMinutes = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
    configSave();
    lastActivityMs = millis();   // restart the countdown from now
  }
  configPublish();
}

void onWriteName(uint16_t conn, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void)conn; (void)chr;
  if (len >= 1 && len <= 15) {
    memcpy(cfg.name, data, len);
    cfg.name[len] = 0;
    configSave();
    // Applied at next boot; the page sends CMD_REBOOT when ready.
  }
  configPublish();
}

void onWriteAccent(uint16_t conn, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void)conn; (void)chr;
  if (len == 1 && data[0] <= ACCENT_BLUE) {
    cfg.accent = data[0];
    configSave();
  }
  configPublish();
}

void onWriteCommand(uint16_t conn, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void)conn; (void)chr;
  if (len == 1) pendingCommand = data[0];   // handled in loop()
}

void configServiceBegin() {
  svcConfig.begin();

  struct { BLECharacteristic* c; uint16_t maxLen; bool fixed;
           BLECharacteristic::write_cb_t cb; } defs[] = {
    { &chrMode,   1,  true,  onWriteMode   },
    { &chrKeymap, 6,  true,  onWriteKeymap },
    { &chrSleep,  2,  true,  onWriteSleep  },
    { &chrName,   15, false, onWriteName   },
    { &chrAccent, 1,  true,  onWriteAccent },
  };
  for (auto& d : defs) {
    d.c->setProperties(CHR_PROPS_READ | CHR_PROPS_WRITE);
    d.c->setPermission(SECMODE_OPEN, SECMODE_OPEN);
    if (d.fixed) d.c->setFixedLen(d.maxLen); else d.c->setMaxLen(d.maxLen);
    d.c->setWriteCallback(d.cb);
    d.c->begin();
  }

  chrBattery.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  chrBattery.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  chrBattery.setFixedLen(4);
  chrBattery.begin();

  chrCommand.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
  chrCommand.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
  chrCommand.setFixedLen(1);
  chrCommand.setWriteCallback(onWriteCommand);
  chrCommand.begin();

  configPublish();
}

// =========================================================================
// Sleep
// =========================================================================
void enterDeepSleep() {
  ledAllOff();
#ifdef ENABLE_EXT_CHARGE_LED
  extOff();
#endif
  // Wake on button press. Wake from system-off is a full chip reset, so
  // setup() runs fresh. P0.14 stays latched LOW through system-off, so
  // the ADC divider keeps P0.31 in safe territory while asleep (2.8uA).
  nrf_gpio_cfg_sense_input(digitalPinToPinName(PIN_BUTTON),
                           NRF_GPIO_PIN_PULLUP,
                           NRF_GPIO_PIN_SENSE_LOW);
  Bluefruit.Advertising.stop();
  sd_power_system_off();
}

// =========================================================================
void connectCallback(uint16_t conn_hdl) {
  (void)conn_hdl;
  ledAccentOn(); delay(200); ledAccentOff();
  // Two concurrent links supported: the iPad/iPhone using the switch,
  // plus a phone or laptop on the config page. Advertising stops on
  // connect, so restart it until both slots are taken.
  if (Bluefruit.Periph.connected() < 2) {
    Bluefruit.Advertising.start(0);
  }
}

void disconnectCallback(uint16_t conn_hdl, uint8_t reason) {
  (void)conn_hdl; (void)reason;
  if (!Bluefruit.Advertising.isRunning()) {
    Bluefruit.Advertising.start(0);
  }
}

// =========================================================================
// Advertised battery. The scan response carries manufacturer data
// [0xFF, 0xFF, percent, state] so the app can show a battery level in the
// "switches nearby" list before connecting. 0xFFFF is the unassigned
// company ID (fine for a DIY device). State matches the battery
// characteristic: 0 = on battery, 1 = charging, 2 = charged on USB.
uint8_t advBattPct   = 100;
uint8_t advBattState = BATT_DISCHARGING;

// Build the advertising + scan-response payload with the current battery.
// Dropping addTxPower keeps headroom for a full 15-char name alongside
// the appearance and HID UUID in the 31-byte main packet.
void buildAdvPayload() {
  Bluefruit.Advertising.clearData();
  Bluefruit.ScanResponse.clearData();

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addAppearance(BLE_APPEARANCE_HID_KEYBOARD);
  Bluefruit.Advertising.addService(blehid);   // 16-bit HID UUID, for iOS
  Bluefruit.Advertising.addName();

  // 128-bit config UUID in the scan response (no room in the main packet),
  // plus the battery manufacturer data. Web Bluetooth and CoreBluetooth
  // both merge the two when filtering, so clients still match the service.
  Bluefruit.ScanResponse.addService(svcConfig);
  uint8_t mfg[4] = { 0xFF, 0xFF, advBattPct, advBattState };
  Bluefruit.ScanResponse.addManufacturerData(mfg, sizeof(mfg));
}

void startAdv() {
  buildAdvPayload();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

// Rebuild and restart advertising when the advertised battery changes.
// Restarting advertising does not disturb an existing connection, and the
// percent changes only every few minutes, so the cost is negligible.
void refreshAdvBattery(uint8_t pct, uint8_t state) {
  if (pct == advBattPct && state == advBattState) return;
  advBattPct   = pct;
  advBattState = state;
  if (Bluefruit.Advertising.isRunning()) {
    Bluefruit.Advertising.stop();
    buildAdvPayload();
    Bluefruit.Advertising.start(0);
  }
}

// =========================================================================
void setup() {
  // Battery pins first: P0.14 LOW keeps the divider enabled and P0.31
  // safely below its absolute maximum at all times.
  pinMode(PIN_BAT_READ_EN, OUTPUT);
  digitalWrite(PIN_BAT_READ_EN, LOW);

#ifdef CHARGE_AT_100MA
  pinMode(PIN_CHARGE_SEL, OUTPUT);
  digitalWrite(PIN_CHARGE_SEL, LOW);    // parallel ISET resistor: 100mA
#else
  pinMode(PIN_CHARGE_SEL, INPUT);       // high-Z: 50mA (default)
#endif

  nrf_gpio_cfg_input(NRF_PIN_CHG, NRF_GPIO_PIN_NOPULL);  // /CHG, has pullup

  pinMode(PIN_BUTTON, INPUT_PULLUP);

  pinMode(LED_RED, OUTPUT); pinMode(LED_GREEN, OUTPUT); pinMode(LED_BLUE, OUTPUT);
  ledAllOff();
#ifdef ENABLE_EXT_CHARGE_LED
  pinMode(EXT_LED_RED, OUTPUT); pinMode(EXT_LED_GREEN, OUTPUT);
  extOff();
#endif

  analogReference(AR_INTERNAL_3_0);
  analogReadResolution(12);

  InternalFS.begin();
  configLoad();

  // Boot battery read: give the divider and ADC a moment, then seed the
  // filter with a real value instead of the 4.0 placeholder.
  delay(10);
  batteryV = readBatteryVoltageOnce();

  // Boot indication: accent flash, then 1-3 blinks for battery level.
  ledAccentOn(); delay(300); ledAllOff();
  uint8_t blinks = (batteryV >= 3.95f) ? 3 : (batteryV >= 3.70f ? 2 : 1);
  delay(200);
  for (uint8_t i = 0; i < blinks; i++) {
    ledAccentOn(); delay(150); ledAccentOff(); delay(150);
  }

  // BLE bring-up. Two peripheral links: HID host + config page.
  Bluefruit.begin(2, 0);
  Bluefruit.autoConnLed(false);   // the sketch owns the RGB LED, not the stack
  Bluefruit.setTxPower(4);
  Bluefruit.setName(cfg.name);
  Bluefruit.Security.setIOCaps(false, false, false);
  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);

  bledfu.begin();   // OTA DFU first, per Bluefruit convention

  bledis.setManufacturer("Open Adaptive Switch");
  bledis.setModel("Adaptive switch v3");
  bledis.setFirmwareRev(FW_VERSION);
  bledis.begin();

  blebas.begin();
  blehid.begin();
  configServiceBegin();

  startAdv();

  batterySample();
  lastActivityMs  = millis();
  lastBatSampleMs = millis();
}

// =========================================================================
// Button handling per mode
// =========================================================================
void onButtonReleased(uint32_t heldMs) {
  switch (cfg.mode) {
    case MODE_TAP_HOLD:
      if (heldMs >= HOLD_MS) {
        sendSlot(1);
        amberConfirmUntilMs = millis() + 150;
      } else {
        sendSlot(0);
      }
      break;
    case MODE_ZONES: {
      uint8_t slot = (heldMs < HOLD_MS) ? 0 : (heldMs < LONG_MS) ? 1 : 2;
      sendSlot(slot);
      // Confirmation flash in the zone color.
      if      (slot == 0) { ledRedOn();   delay(80); ledRedOff(); }
      else if (slot == 1) { ledAmberOn(); delay(80); ledAllOff(); }
      else                { ledGreenOn(); delay(80); ledGreenOff(); }
      break;
    }
    default:
      break;   // MODE_SINGLE fires on press, not release
  }
}

// Live LED feedback while the button is held.
void heldFeedback(uint32_t heldMs) {
  switch (cfg.mode) {
    case MODE_TAP_HOLD:
      // Brief accent flash on press, quiet gap, then solid accent once
      // the hold threshold is crossed so the user knows when to let go.
      if      (heldMs < 120)     ledAccentOn();
      else if (heldMs < HOLD_MS) ledAllOff();
      else                       ledAccentOn();
      break;
    case MODE_ZONES:
      // Zone color while held: red short, amber medium, green long.
      if      (heldMs < HOLD_MS) { ledRedOn();  ledGreenOff(); }
      else if (heldMs < LONG_MS) { ledAmberOn();               }
      else                       { ledRedOff(); ledGreenOn();  }
      break;
    default:
      break;
  }
}

// =========================================================================
// Idle status LED, priority order: amber confirm, critical, charging,
// low, advertising, connected-idle.
// =========================================================================
void updateStatusLed(uint32_t now) {
  if ((int32_t)(amberConfirmUntilMs - now) > 0) { ledAmberOn(); return; }

  if (batteryV < BAT_CRITICAL_V && batteryState == BATT_DISCHARGING) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledRedOn(); else ledRedOff();
    ledGreenOff(); ledBlueOff();
    return;
  }
  if (batteryState == BATT_CHARGING) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledPurpleOn(); else ledAllOff();
    return;
  }
  if (batteryV < BAT_LOW_V && batteryState == BATT_DISCHARGING) {
    ledRedOn(); ledGreenOff(); ledBlueOff();
    return;
  }
  if (Bluefruit.Periph.connected() == 0) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledAccentOn(); else ledAccentOff();
    return;
  }
  ledAllOff();
}

// =========================================================================
void loop() {
  uint32_t now = millis();

  // Deferred commands from the config service (never reset inside a BLE
  // callback; let the write response go out first).
  if (pendingCommand) {
    uint8_t command = pendingCommand;
    pendingCommand = 0;
    delay(100);
    switch (command) {
      case CMD_REBOOT:
        NVIC_SystemReset();
        break;
      case CMD_FACTORY_RESET:
        configDefaults();
        configSave();
        NVIC_SystemReset();
        break;
      case CMD_ENTER_DFU:
        enterOTADfu();   // reboots into the OTA bootloader
        break;
      default:
        break;
    }
  }

  // Button edges, debounced. MODE_SINGLE fires on press for the lowest
  // possible latency; the other modes measure duration and fire on
  // release.
  bool b = digitalRead(PIN_BUTTON);
  if (b != buttonPrev && (now - buttonChangeMs) > DEBOUNCE_MS) {
    buttonChangeMs = now;
    buttonPrev = b;
    if (b == LOW) {
      buttonDownAtMs = now;
      lastActivityMs = now;
      if (cfg.mode == MODE_SINGLE) {
        ledAccentOn();
        sendSlot(0);
        delay(50);
        ledAccentOff();
      }
    } else {
      ledAllOff();
      onButtonReleased(now - buttonDownAtMs);
      lastActivityMs = now;
    }
  }

  if (buttonPrev == LOW && cfg.mode != MODE_SINGLE) {
    heldFeedback(now - buttonDownAtMs);
  } else {
    updateStatusLed(now);
  }

#ifdef ENABLE_EXT_CHARGE_LED
  updateChargeLed(now);
#endif

  if (now - lastBatSampleMs > BAT_SAMPLE_MS) {
    lastBatSampleMs = now;
    batterySample();
  }

  // Inactivity sleep, runtime-configurable; 0 disables. Skipped while on
  // USB power so a switch used at a desk never vanishes mid-session.
  if (cfg.sleepMinutes > 0 && !usbPowered()) {
    uint32_t timeoutMs = (uint32_t)cfg.sleepMinutes * 60UL * 1000UL;
    if (now - lastActivityMs > timeoutMs) {
      enterDeepSleep();
    }
  }

  delay(5);
}
