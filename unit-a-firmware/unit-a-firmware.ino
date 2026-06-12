// =========================================================================
// Open Adaptive Switch - UNIT A  (canonical "tap" switch, F13)
// Target: Seeed XIAO nRF52840 Sense
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors
//
// This is the canonical firmware that all other units derive from
// (via make_unit.sh). To create a new unit, change ONLY the three
// per-unit lines in the SETTINGS block below: DEVICE_NAME, HID_KEY,
// and UNIT_LED_COLOR_*. Everything else stays identical.
//
// Features:
//   - Under-voltage lockout (UVLO): chip auto-sleeps if LiPo drops
//     below ~3.1V, preventing damaging deep discharge.
//     NOTE: units B and C dropped UVLO after false shutdowns (BLE TX
//     bursts can briefly sag the rail below 3.10V on a healthy cell).
//     Unit A keeps it while the variants are compared side by side.
//   - Toggleable inactivity sleep (ENABLE_INACTIVITY_SLEEP).
//   - Placeholder block for a future multi-position selector switch.
//   - Wake from deep sleep = full chip reset (sd_power_system_off),
//     so setup() runs fresh every wake, including the battery check.
//
// See README.md for the project overview and SETUP.md for the
// build/flash environment.
// =========================================================================

#include <bluefruit.h>

// =========================================================================
// ====================== SETTINGS YOU MIGHT CHANGE ========================
// =========================================================================

// ---- Firmware version (reported via BLE Device Information Service) ----
// Bump this when the underlying code changes. Identity (DEVICE_NAME, HID_KEY)
// is per-unit; version is per-codebase and stays the same across all units.
#define FW_VERSION "2.0.1"   // 2.0.1: BLE name GameSwitch-A -> AdaptSwitch-A

// ---- Per-unit identity ----
// To make a new unit, change ONLY these two lines and the LED color block
// below. Everything else stays identical.
// Keep the name 15 chars or fewer: the advertising packet is 31 bytes,
// and flags + TX power + appearance + HID UUID leave room for a 15-char
// complete name. (The full name is still readable after connect via the
// GAP device-name characteristic.)
const char*   DEVICE_NAME = "AdaptSwitch-A";
const uint8_t HID_KEY     = HID_KEY_F13;

// ---- Button pin ----
// XIAO nRF52840 Sense pin labels D0..D10 are all valid INPUT_PULLUP options.
const uint8_t PIN_BUTTON = D0;

// ---- Inactivity auto-sleep ----------------------------------------------
// Comment the line below out to DISABLE inactivity sleep entirely.
// (Useful if you're always on USB and don't want the device sleeping.)
#define ENABLE_INACTIVITY_SLEEP

// How long with no button press before sleeping.
// Edit this number to change the timeout. Format is hours/min/ms math
// so you can read it at a glance.
const uint32_t SLEEP_TIMEOUT_MS = 30UL * 60UL * 1000UL;  // 30 minutes
// Examples for quick reference:
//   const uint32_t SLEEP_TIMEOUT_MS =  5UL * 60UL * 1000UL;  //  5 min
//   const uint32_t SLEEP_TIMEOUT_MS =  1UL * 60UL * 60UL * 1000UL;  // 1 hr
//   const uint32_t SLEEP_TIMEOUT_MS =  8UL * 60UL * 60UL * 1000UL;  // 8 hr

// ---- Multi-position selector (future expansion) -------------------------
// Wire a slide switch or rotary selector to choose between sleep timeouts
// (or HID keys, or any other runtime mode) without reflashing.
// Suggested pins: D2 + D3 (gives 4 combinations with a 2-throw switch).
//
// To enable, uncomment the #define and the readSelector() body below,
// then call readSelector() in setup() to override the defaults.
//
// #define ENABLE_MODE_SELECTOR
// const uint8_t PIN_MODE_A = D2;
// const uint8_t PIN_MODE_B = D3;
// uint32_t readSelectorTimeout() {
//   pinMode(PIN_MODE_A, INPUT_PULLUP);
//   pinMode(PIN_MODE_B, INPUT_PULLUP);
//   bool a = digitalRead(PIN_MODE_A) == LOW;
//   bool b = digitalRead(PIN_MODE_B) == LOW;
//   if (a && !b) return  5UL * 60UL * 1000UL;       //  5 min
//   if (!a && b) return 60UL * 60UL * 1000UL;       //  1 hr
//   if (a && b)  return 24UL * 60UL * 60UL * 1000UL;// 24 hr ("always on-ish")
//   return SLEEP_TIMEOUT_MS;                        // default
// }
// In setup(), after the #ifdef block: runtimeSleepTimeoutMs = readSelectorTimeout();

// ---- Battery protection (LiPo 3.7V cell) --------------------------------
// LiPo cells should never go below ~3.0V or they're damaged. We sleep
// the chip below BAT_SHUTDOWN_V to make that physically impossible.
const float BAT_LOW_V       = 3.55;  // solid red status LED
const float BAT_CRITICAL_V  = 3.35;  // blinking red status LED
const float BAT_SHUTDOWN_V  = 3.10;  // emergency sleep — DO NOT lower this
                                     // unless you've changed cell chemistry.
// How often to re-check battery (ms). Default 10s during operation.
const uint32_t BAT_CHECK_MS = 10000;
// Skip the first few battery reads — the ADC takes a moment to stabilize
// on cold boot. Without this you can get a false-low reading and shut
// down at startup even with a full battery.
const uint8_t  BAT_WARMUP_READS = 3;

// ---- LED color for this unit (per-unit signature) -----------------------
// Each unit can have a different "accent color" for the advertising pulse
// and button feedback. Pick R, G, or B (the onboard LED is RGB).
#define UNIT_LED_COLOR_RED       // <-- change to UNIT_LED_COLOR_GREEN/BLUE for other units

// =========================================================================
// ==================== END SETTINGS — code below ==========================
// =========================================================================

#define PIN_BAT_READ_EN  (32 + 14)
#define PIN_VBAT_ADC     (0  + 31)
#define PIN_CHARGE_SEL   (0  + 13)

const uint32_t DEBOUNCE_MS         = 30;
const uint32_t LED_PULSE_PERIOD_MS = 1500;

BLEDis bledis;
BLEHidAdafruit blehid;

uint32_t lastActivityMs = 0;
uint32_t lastBatCheckMs = 0;
float    lastBatV = 4.0;
uint8_t  batReadsTaken = 0;
bool     buttonPrev = HIGH;
uint32_t buttonChangeMs = 0;
bool     isConnected = false;

// Sleep timeout actually used at runtime — defaults to SLEEP_TIMEOUT_MS,
// but the multi-position selector (if enabled) overrides this in setup().
uint32_t runtimeSleepTimeoutMs = SLEEP_TIMEOUT_MS;

// =========================================================================
// LED helpers — common-anode (LOW = ON)
// =========================================================================
void ledRedOn()    { digitalWrite(LED_RED,   LOW);  }
void ledRedOff()   { digitalWrite(LED_RED,   HIGH); }
void ledGreenOn()  { digitalWrite(LED_GREEN, LOW);  }
void ledGreenOff() { digitalWrite(LED_GREEN, HIGH); }
void ledBlueOn()   { digitalWrite(LED_BLUE,  LOW);  }
void ledBlueOff()  { digitalWrite(LED_BLUE,  HIGH); }
void ledAllOff()   { ledRedOff(); ledGreenOff(); ledBlueOff(); }
void ledAmberOn()  { ledRedOn();  ledGreenOn(); }

// Per-unit accent (driven by UNIT_LED_COLOR_* define above)
#if defined(UNIT_LED_COLOR_GREEN)
  #define ledAccentOn()  ledGreenOn()
  #define ledAccentOff() ledGreenOff()
#elif defined(UNIT_LED_COLOR_BLUE)
  #define ledAccentOn()  ledBlueOn()
  #define ledAccentOff() ledBlueOff()
#else  // default red
  #define ledAccentOn()  ledRedOn()
  #define ledAccentOff() ledRedOff()
#endif

// =========================================================================
float readBatteryVoltage() {
  digitalWrite(PIN_BAT_READ_EN, LOW);
  delay(10);
  uint32_t raw = analogRead(PIN_VBAT_ADC);
  digitalWrite(PIN_BAT_READ_EN, HIGH);
  float vPin = (float)raw * (3.0f / 4096.0f);
  return vPin * (1510.0f / 510.0f);
}

// =========================================================================
// Visible "I'm shutting down, please charge me" signal — 5 fast red blinks
// then deep sleep.
// =========================================================================
void emergencyShutdown() {
  for (int i = 0; i < 5; i++) {
    ledRedOn();  delay(80);
    ledRedOff(); delay(80);
  }
  enterDeepSleep();
}

// =========================================================================
void enterDeepSleep() {
  ledAllOff();
  // Configure button pin to wake the chip on press.
  nrf_gpio_cfg_sense_input(digitalPinToPinName(PIN_BUTTON),
                           NRF_GPIO_PIN_PULLUP,
                           NRF_GPIO_PIN_SENSE_LOW);
  Bluefruit.Advertising.stop();
  // sd_power_system_off() is the deepest sleep mode. Wake from it is a
  // full chip RESET — meaning when the user next presses the button (or
  // USB is plugged in), setup() runs again from the top. This is intended.
  sd_power_system_off();
}

// =========================================================================
void setup() {
  pinMode(PIN_CHARGE_SEL, OUTPUT);
  digitalWrite(PIN_CHARGE_SEL, HIGH);   // 50mA charge current

  pinMode(PIN_BUTTON, INPUT_PULLUP);

  pinMode(LED_RED,   OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE,  OUTPUT);
  ledAllOff();

  pinMode(PIN_BAT_READ_EN, OUTPUT);
  digitalWrite(PIN_BAT_READ_EN, HIGH);

  analogReference(AR_INTERNAL_3_0);
  analogReadResolution(12);

  // ---- Boot-time battery check ----
  // Take a few readings to let the ADC settle, then act on the average.
  float vSum = 0;
  for (uint8_t i = 0; i < BAT_WARMUP_READS; i++) {
    vSum += readBatteryVoltage();
    delay(20);
  }
  lastBatV = vSum / BAT_WARMUP_READS;
  batReadsTaken = BAT_WARMUP_READS;

  // If the cell is below the protection threshold AT BOOT, refuse to run.
  // The user will see 5 red blinks and the chip sleeps. Pressing the
  // button again will reboot us — we'll re-check and sleep again until
  // USB power lifts the rail above the threshold (i.e. charging).
  if (lastBatV < BAT_SHUTDOWN_V) {
    emergencyShutdown();
  }

  // ---- Optional multi-position selector read ----
  // #ifdef ENABLE_MODE_SELECTOR
  //   runtimeSleepTimeoutMs = readSelectorTimeout();
  // #endif

  // ---- Boot indication: brief accent flash ----
  ledAccentOn();
  delay(300);
  ledAllOff();

  // ---- BLE init ----
  Bluefruit.begin();
  Bluefruit.setTxPower(4);
  Bluefruit.setName(DEVICE_NAME);
  Bluefruit.Security.setIOCaps(false, false, false);

  Bluefruit.Periph.setConnectCallback(onConnect);
  Bluefruit.Periph.setDisconnectCallback(onDisconnect);

  bledis.setManufacturer("Open Adaptive Switch");
  bledis.setModel("Unit A (tap switch)");
  bledis.setFirmwareRev(FW_VERSION);
  bledis.begin();

  blehid.begin();
  startAdv();

  showBatteryLevelBlinks(lastBatV);

  lastActivityMs = millis();
  lastBatCheckMs = millis();
}

// =========================================================================
void startAdv() {
  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addAppearance(BLE_APPEARANCE_HID_KEYBOARD);
  Bluefruit.Advertising.addService(blehid);
  Bluefruit.Advertising.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

void onConnect(uint16_t h) {
  isConnected = true;
  ledAccentOn(); delay(200); ledAccentOff();
}

void onDisconnect(uint16_t h, uint8_t reason) {
  isConnected = false;
}

// =========================================================================
void loop() {
  uint32_t now = millis();

  // Button (with debounce)
  bool b = digitalRead(PIN_BUTTON);
  if (b != buttonPrev && (now - buttonChangeMs) > DEBOUNCE_MS) {
    buttonChangeMs = now;
    buttonPrev = b;
    if (b == LOW) {
      onButtonPressed();
      lastActivityMs = now;
    }
  }

  // Periodic battery check — sleeps the device if voltage too low.
  if (now - lastBatCheckMs > BAT_CHECK_MS) {
    lastBatCheckMs = now;
    lastBatV = readBatteryVoltage();
    if (lastBatV < BAT_SHUTDOWN_V) {
      emergencyShutdown();   // never returns
    }
  }

  updateStatusLed(now);

  // ============== INACTIVITY SLEEP BLOCK (toggle at top) ==============
  // Wrapped in #ifdef so you can disable the whole thing by commenting
  // out the ENABLE_INACTIVITY_SLEEP define at the top of the file.
  #ifdef ENABLE_INACTIVITY_SLEEP
    if (now - lastActivityMs > runtimeSleepTimeoutMs) {
      enterDeepSleep();
      // enterDeepSleep() does not return — wake is a chip reset, so this
      // line is only ever reached if sleep failed (shouldn't happen).
      lastActivityMs = millis();
    }
  #endif
  // ====================================================================

  delay(5);
}

// =========================================================================
void onButtonPressed() {
  ledAccentOn();
  if (isConnected) {
    blehid.keyPress(HID_KEY);
    delay(15);
    blehid.keyRelease();
  }
  delay(50);
  ledAccentOff();
}

// =========================================================================
void updateStatusLed(uint32_t now) {
  if (lastBatV < BAT_CRITICAL_V) {
    // Blinking red — critical battery, charge soon
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledRedOn(); else ledRedOff();
    ledGreenOff(); ledBlueOff();
  } else if (lastBatV < BAT_LOW_V) {
    // Solid red — battery low
    ledRedOn();
    ledGreenOff(); ledBlueOff();
  } else if (!isConnected) {
    // Pulse accent color while advertising (not yet paired)
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledAccentOn(); else ledAccentOff();
  } else {
    ledAllOff();
  }
}

// =========================================================================
void showBatteryLevelBlinks(float v) {
  uint8_t n = (v >= 3.95) ? 3 : (v >= 3.70 ? 2 : 1);
  delay(200);
  for (uint8_t i = 0; i < n; i++) {
    ledAccentOn();  delay(150);
    ledAccentOff(); delay(150);
  }
}
