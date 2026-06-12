// =========================================================================
// Open Adaptive Switch - UNIT B  (MEDIA REMOTE — keyboard SPACE)
// Target: Seeed XIAO nRF52840 Sense
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors
//
// What's different from Unit A:
//   - Short press → HID_KEY_SPACE (play/pause).
//   - Long  press → HID_KEY_LONG (defaults to F14 — see settings below).
//     This gives one physical button two distinct actions: tap for
//     play/pause, hold for a separate iOS Switch Control trigger.
//   - Intended use: pair as a plain Bluetooth keyboard with iOS Switch
//     Control turned OFF (or with selective bindings). SPACE toggles
//     play/pause in YouTube, Apple Music, etc. WITHOUT revealing the
//     on-screen player overlay (a screen-tap reveals controls; a
//     keyboard event doesn't).
//
// Alternative — true media-remote consumer key (slightly cleaner
// semantically, same effect in most apps):
//   In onButtonReleased(), replace the blehid.keyPress/Release pair with:
//     blehid.consumerKeyPress(HID_USAGE_CONSUMER_PLAY_PAUSE);
//     delay(15);
//     blehid.consumerKeyRelease();
//
// All the v2 chassis (sleep block, selector placeholder) is inherited
// from unit-a-firmware unchanged. See README.md for the project overview
// and SETUP.md for the build/flash environment.
//
// Note: the v2.0 low-voltage emergency shutdown (UVLO) was removed in
// v2.1.0 because BLE TX current spikes briefly sagged the rail below
// the 3.10V threshold on a healthy cell, triggering false shutdowns.
// Low battery is now indicated by the status LED only (solid red /
// blinking red) — matching the v1.0 unit-A behavior.
//
// LED vocabulary (v2.3.0):
//   blink red         battery critical (< 3.35V)
//   green flash burst voltage readout every 30s — N flashes = integer
//                     volts, pause, M flashes = tenths (e.g. 3 + 7 = 3.7V)
//   blue flash        button registered (~100ms on press)
//   blue solid        button held past long-press threshold (500ms)
//   amber flash       long-press fired on release
//   purple pulse      USB power detected and cell not yet full (charging)
//   solid red         battery low (3.35–3.55V) and not charging
//   blue pulse        advertising / not paired
//   off               connected, idle
// =========================================================================

#include <bluefruit.h>

// =========================================================================
// ====================== SETTINGS YOU MIGHT CHANGE ========================
// =========================================================================

// ---- Firmware version (reported via BLE Device Information Service) ----
// Bump this when the underlying code changes. Identity (DEVICE_NAME, HID_KEY)
// is per-unit; version is per-codebase and stays the same across all units.
#define FW_VERSION "2.3.1"   // 2.3.1: BLE name GameSwitch-B -> AdaptSwitch-B

// ---- Per-unit identity ----
// To make a new unit, change ONLY these two lines and the LED color block
// below. Everything else stays identical.
// Keep the name 15 chars or fewer: the advertising packet is 31 bytes,
// and flags + TX power + appearance + HID UUID leave room for a 15-char
// complete name. (The full name is still readable after connect via the
// GAP device-name characteristic.)
const char*   DEVICE_NAME = "AdaptSwitch-B";
const uint8_t HID_KEY     = HID_KEY_SPACE;

// ---- Long-press second action ----
// On release, the firmware compares the time the button was held to
// LONG_PRESS_MS. Short press sends HID_KEY (above). Long press sends
// HID_KEY_LONG. Set HID_KEY_LONG to the same value as HID_KEY to make
// long press behave identically to short press (effectively disabling
// the feature). F13/F15/F16/F17 are used by other units in the project,
// so F14 is a safe default that won't collide if multiple units are
// paired to the same iOS device.
const uint8_t  HID_KEY_LONG  = HID_KEY_F14;
const uint32_t LONG_PRESS_MS = 500;   // hold this long → long press

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

// ---- Battery indication (LiPo 3.7V cell) --------------------------------
// LiPo cells should never go below ~3.0V or they're damaged, but we only
// indicate that via the status LED — no auto-shutdown. (The v2.0 UVLO
// caused false shutdowns when BLE TX bursts briefly sagged the rail.)
const float BAT_LOW_V       = 3.55;  // solid red status LED
const float BAT_CRITICAL_V  = 3.35;  // blinking red status LED
const float BAT_FULL_V      = 4.15;  // suppress "charging" pulse above this
// How often to re-check battery (ms). Default 30s during operation.
const uint32_t BAT_CHECK_MS = 30000;
// How often to flash the voltage readout (N green flashes + pause + M
// green flashes, encoding the cell voltage like "3 . 7" for 3.7V).
const uint32_t BAT_REPORT_MS = 30000;
// Average the first few battery reads on boot — the ADC takes a moment
// to stabilize on cold boot, and we want a sensible initial reading for
// the boot-time level blinks.
const uint8_t  BAT_WARMUP_READS = 3;

// ---- LED color for this unit (per-unit signature) -----------------------
// Each unit can have a different "accent color" for the advertising pulse
// and button feedback. Pick R, G, or B (the onboard LED is RGB).
#define UNIT_LED_COLOR_BLUE

// =========================================================================
// ==================== END SETTINGS — code below ==========================
// =========================================================================

#define PIN_BAT_READ_EN  (32 + 14)
#define PIN_VBAT_ADC     (0  + 31)
#define PIN_CHARGE_SEL   (0  + 13)

const uint32_t DEBOUNCE_MS         = 30;
const uint32_t LED_PULSE_PERIOD_MS = 1500;
// Brief blue flash on press-down to confirm the press registered.
// If the button keeps being held past LONG_PRESS_MS, the LED comes back
// on solid blue to signal "long-press zone reached — safe to release."
const uint32_t PRESS_FLASH_MS      = 120;
// Voltage-readout timing: 80ms on / 80ms off per flash, 400ms pause
// between the integer portion and the tenths portion.
const uint32_t VR_FLASH_ON_MS      = 80;
const uint32_t VR_FLASH_OFF_MS     = 80;
const uint32_t VR_GAP_MS           = 400;
// Amber confirmation flash duration on long-press release.
const uint32_t AMBER_CONFIRM_MS    = 150;

BLEDis bledis;
BLEHidAdafruit blehid;

uint32_t lastActivityMs = 0;
uint32_t lastBatCheckMs = 0;
uint32_t lastVoltageReportMs = 0;
float    lastBatV = 4.0;
uint8_t  batReadsTaken = 0;
bool     buttonPrev = HIGH;
uint32_t buttonChangeMs = 0;
uint32_t buttonDownMs   = 0;   // when the current press began
uint32_t amberConfirmUntilMs = 0;   // long-press release confirm window
bool     isConnected = false;

// ---- Voltage-readout state machine ----
// Cycles through: integer flashes → gap → tenths flashes → idle.
// Runs every BAT_REPORT_MS, non-blocking so the button stays responsive.
enum VoltageReportState {
  VR_IDLE,
  VR_INT_ON,  VR_INT_OFF,   // integer-volts flashes
  VR_GAP,                    // pause between integer and tenths
  VR_DEC_ON,  VR_DEC_OFF     // tenths flashes
};
VoltageReportState vrState = VR_IDLE;
uint32_t vrNextStepMs = 0;
uint8_t  vrIntLeft = 0;
uint8_t  vrDecLeft = 0;

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
void ledPurpleOn() { ledRedOn();  ledBlueOn(); ledGreenOff(); }

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
// USB power detection — reads the nRF52840's hardware VBUS-detect bit.
// True whenever 5V is present on the USB connector, regardless of whether
// a host has opened the CDC serial port. Used to drive the "charging"
// purple pulse so we still know power is reaching the board even if
// the onboard orange CHG LED is broken or not wired through.
// =========================================================================
bool usbPowered() {
  return (NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk) != 0;
}

// =========================================================================
// Voltage-readout state machine.
//
// startVoltageReport(v) kicks off a non-blocking sequence:
//   N green flashes (integer volts) → 400ms pause → M green flashes
//   (tenths). E.g. v=3.7 → 3 flashes, pause, 7 flashes.
//
// advanceVoltageReport(now) must be called every loop iteration; it
// progresses the state machine when the current step's deadline arrives.
//
// Sequence skipped if the button is being held (we don't want the
// status LED hijacking visual feedback during a press).
// =========================================================================
void startVoltageReport(float v) {
  if (vrState != VR_IDLE) return;
  if (v < 0) v = 0;
  if (v > 9.9f) v = 9.9f;
  uint8_t intPart = (uint8_t)v;
  uint8_t decPart = (uint8_t)((v - intPart) * 10.0f + 0.5f);  // round
  if (decPart > 9) { decPart = 0; intPart++; }
  vrIntLeft = intPart;
  vrDecLeft = decPart;
  // If integer is 0, jump straight to the gap so we still show the tenths.
  if (vrIntLeft > 0) {
    ledGreenOn();
    vrState = VR_INT_ON;
    vrNextStepMs = millis() + VR_FLASH_ON_MS;
  } else {
    vrState = VR_GAP;
    vrNextStepMs = millis() + VR_GAP_MS;
  }
}

void advanceVoltageReport(uint32_t now) {
  if (vrState == VR_IDLE) return;
  if ((int32_t)(now - vrNextStepMs) < 0) return;

  switch (vrState) {
    case VR_INT_ON:
      ledGreenOff();
      vrIntLeft--;
      if (vrIntLeft > 0) {
        vrState = VR_INT_OFF;
        vrNextStepMs = now + VR_FLASH_OFF_MS;
      } else {
        vrState = VR_GAP;
        vrNextStepMs = now + VR_GAP_MS;
      }
      break;
    case VR_INT_OFF:
      ledGreenOn();
      vrState = VR_INT_ON;
      vrNextStepMs = now + VR_FLASH_ON_MS;
      break;
    case VR_GAP:
      if (vrDecLeft > 0) {
        ledGreenOn();
        vrState = VR_DEC_ON;
        vrNextStepMs = now + VR_FLASH_ON_MS;
      } else {
        vrState = VR_IDLE;   // no tenths to show → done
      }
      break;
    case VR_DEC_ON:
      ledGreenOff();
      vrDecLeft--;
      if (vrDecLeft > 0) {
        vrState = VR_DEC_OFF;
        vrNextStepMs = now + VR_FLASH_OFF_MS;
      } else {
        vrState = VR_IDLE;
      }
      break;
    case VR_DEC_OFF:
      ledGreenOn();
      vrState = VR_DEC_ON;
      vrNextStepMs = now + VR_FLASH_ON_MS;
      break;
    default:
      vrState = VR_IDLE;
      break;
  }
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
  bledis.setModel("Unit B (media remote)");
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

  // Button — track both edges so we can measure press duration.
  // The LED state for "press registered / long-press zone reached" is
  // driven by updateStatusLed() based on (now - buttonDownMs); we don't
  // touch the LED directly here.
  bool b = digitalRead(PIN_BUTTON);
  if (b != buttonPrev && (now - buttonChangeMs) > DEBOUNCE_MS) {
    buttonChangeMs = now;
    buttonPrev = b;
    if (b == LOW) {
      buttonDownMs = now;
      lastActivityMs = now;
    } else {
      onButtonReleased(now - buttonDownMs);
      lastActivityMs = now;
    }
  }

  // Periodic battery check — only updates the LED indicator, no shutdown.
  if (now - lastBatCheckMs > BAT_CHECK_MS) {
    lastBatCheckMs = now;
    lastBatV = readBatteryVoltage();
  }

  // Voltage readout — kick off every BAT_REPORT_MS, but only when nothing
  // else is using the LED (idle state machine + button not held).
  if (vrState == VR_IDLE
      && buttonPrev == HIGH
      && (now - lastVoltageReportMs) > BAT_REPORT_MS) {
    lastVoltageReportMs = now;
    startVoltageReport(lastBatV);
  }
  advanceVoltageReport(now);

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
// Called on button release. heldMs is how long the button was held down.
// Short release sends HID_KEY; long release sends HID_KEY_LONG and arms
// a non-blocking amber confirm window (rendered by updateStatusLed).
void onButtonReleased(uint32_t heldMs) {
  bool longPress = (heldMs >= LONG_PRESS_MS);
  if (isConnected) {
    uint8_t key = longPress ? HID_KEY_LONG : HID_KEY;
    blehid.keyPress(key);
    delay(15);
    blehid.keyRelease();
  }
  if (longPress) {
    amberConfirmUntilMs = millis() + AMBER_CONFIRM_MS;
  }
}

// =========================================================================
// Priority order (highest → lowest):
//   1. Voltage-readout state machine is running (its own LED control).
//   2. Amber long-press confirm window is active.
//   3. Button is currently held: blue flash, gap, then solid blue once
//      we've crossed LONG_PRESS_MS so the user can tell when to release.
//   4. Critical battery: blink red (safety — wins over charging).
//   5. USB power present + cell not full: purple pulse (charging).
//   6. Low battery (and not charging): solid red.
//   7. Advertising (not paired): pulse accent (blue for unit B).
//   8. Connected, idle: off.
// =========================================================================
void updateStatusLed(uint32_t now) {
  // 1. Voltage report owns the LED while running.
  if (vrState != VR_IDLE) return;

  // 2. Amber confirm window — short-lived flash after a long-press release.
  if ((int32_t)(amberConfirmUntilMs - now) > 0) {
    ledAmberOn();
    return;
  }

  // 3. Button currently held — drive LED off the held duration.
  if (buttonPrev == LOW) {
    uint32_t heldMs = now - buttonDownMs;
    if (heldMs < PRESS_FLASH_MS) {
      ledAccentOn();        // brief press-confirmation flash
    } else if (heldMs < LONG_PRESS_MS) {
      ledAllOff();           // quiet gap while waiting to see long press
    } else {
      ledAccentOn();        // solid blue: long-press zone reached
    }
    return;
  }

  // 4. Critical battery wins regardless of charging.
  if (lastBatV < BAT_CRITICAL_V) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledRedOn(); else ledRedOff();
    ledGreenOff(); ledBlueOff();
    return;
  }

  // 5. Charging — purple pulse whenever USB is present and the cell hasn't
  //    reached full. Even if the onboard orange CHG LED isn't visible/wired,
  //    this is firmware-side confirmation that USB power has reached the
  //    chip. If the cell voltage isn't climbing across successive 30s
  //    readouts despite this pulsing, the cell-to-BAT-pad path is broken.
  if (usbPowered() && lastBatV < BAT_FULL_V) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledPurpleOn(); else ledAllOff();
    return;
  }

  // 6. Low battery, not charging.
  if (lastBatV < BAT_LOW_V) {
    ledRedOn();
    ledGreenOff(); ledBlueOff();
    return;
  }

  // 7. Advertising — pulse accent.
  if (!isConnected) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledAccentOn(); else ledAccentOff();
    return;
  }

  // 8. Connected idle.
  ledAllOff();
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
