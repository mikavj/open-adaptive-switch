// =========================================================================
// Open Adaptive Switch - UNIT C  (MULTI-MODE TIMING BUTTON)
// Target: Seeed XIAO nRF52840 Sense
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors
//
// What's different from other units:
//   One physical button → THREE distinct HID outputs, chosen by press
//   duration. iOS sees each duration as a separate switch in Switch
//   Control (add each one via "External" → press the button at the
//   right duration → assign action).
//
//     Short  press (<500ms)        → KEY_SHORT  (HID_KEY_F15)
//     Medium press (500ms–2000ms)  → KEY_MEDIUM (HID_KEY_F16)
//     Long   press (>2000ms)       → KEY_LONG   (HID_KEY_F17)
//
//   These three F-keys are deliberately distinct from the other units so
//   multiple switches can be paired to the same iOS device at once:
//     Unit A → F13            Unit B → SPACE (tap) + F14 (hold)
//     Unit C → F15 / F16 / F17
//   SPACE is intentionally NOT used here — Unit B already owns it, and the
//   whole point of these units is that each one is a *distinct* switch.
//
// Live feedback while held — LED color tells you what zone you're in
// BEFORE you release:
//     red    = short zone
//     amber  = medium zone   (red + green)
//     green  = long zone
//
// CHASSIS: this unit now uses the same v2.3.0 chassis as Unit B.
//   - The v2.0 low-voltage emergency shutdown (UVLO) was REMOVED because
//     BLE TX current spikes briefly sagged the rail below the 3.10V
//     threshold on a healthy cell, triggering false shutdowns. Low battery
//     is now indicated by the status LED only (solid red / blinking red).
//   - USB power is detected via the nRF52840 hardware VBUS bit and shown
//     as a purple charging pulse (idle only).
//   - Cell voltage is reported every 30s as a non-blocking green flash
//     burst (N flashes = integer volts, pause, M flashes = tenths).
//
// All the v2 chassis (sleep block, selector placeholder) is inherited from
// unit-a/unit-b unchanged. See README.md for the project overview and
// SETUP.md for the build/flash environment.
//
// EXTERNAL CHARGE LED (v2.4.x, Unit C only): an optional panel-mount
// common-cathode red/green bi-color LED on D9/D10 mirrors charge status
// where the onboard LED can't be seen (e.g. inside an enclosure). It is
// fully independent of the onboard RGB LED. See the settings block below
// for the wiring. This is the only divergence from the shared chassis, so
// Unit C's FW_VERSION is at 2.4.x while B is at 2.3.x (and A, still on
// the older UVLO chassis, at 2.0.x).
//
// Onboard LED vocabulary (v2.3.0):
//   red/amber/green   live press-duration zone while button is held
//   red → amber →     boot sequence teaching the three zones
//     green
//   blink red         battery critical (< 3.35V)
//   green flash burst voltage readout every 30s — N flashes = integer
//                     volts, pause, M flashes = tenths (e.g. 3 + 7 = 3.7V)
//   purple pulse      USB power detected and cell not yet full (charging)
//   solid red         battery low (3.35–3.55V) and not charging
//   red pulse         advertising / not paired
//   off               connected, idle
//
// External bi-color charge LED (D9 = red, D10 = green, common cathode):
//   solid red         charging (USB present, cell below full)
//   solid green       charged  (USB present, cell >= 4.15V)
//   blink red         on battery and critical (< 3.35V) — low-batt alarm
//   off               on battery and healthy (saves cell current)
// =========================================================================

#include <bluefruit.h>

// =========================================================================
// ====================== SETTINGS YOU MIGHT CHANGE ========================
// =========================================================================

// ---- Firmware version (reported via BLE Device Information Service) ----
// Bump this when the underlying code changes. Identity (DEVICE_NAME, keys)
// is per-unit; version is per-codebase. Unit C is at 2.4.x (one feature
// ahead of B's 2.3.x): it adds the external bi-color charge LED below.
#define FW_VERSION "2.4.1"   // 2.4.1: BLE name GameSwitch-C -> AdaptSwitch-C

// ---- Per-unit identity ----
// Keep the name 15 chars or fewer: the advertising packet is 31 bytes,
// and flags + TX power + appearance + HID UUID leave room for a 15-char
// complete name. (The full name is still readable after connect via the
// GAP device-name characteristic.)
const char* DEVICE_NAME = "AdaptSwitch-C";

// ---- Per-duration HID keys (change these to remap the three actions) ----
// Kept distinct from Unit A (F13) and Unit B (SPACE / F14) so all units can
// be paired to the same iOS device without their switches colliding.
const uint8_t KEY_SHORT  = HID_KEY_F15;
const uint8_t KEY_MEDIUM = HID_KEY_F16;
const uint8_t KEY_LONG   = HID_KEY_F17;

// ---- Press duration thresholds (ms) ----
const uint32_t SHORT_PRESS_MAX_MS  = 500;   //  <500ms = SHORT
const uint32_t MEDIUM_PRESS_MAX_MS = 2000;  //  500–2000ms = MEDIUM, >2000ms = LONG

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
// Each unit can have a different "accent color" for the advertising pulse.
// Pick R, G, or B (the onboard LED is RGB). Unit C uses RED. Note the live
// press-duration feedback (red/amber/green) is independent of this accent.
#define UNIT_LED_COLOR_RED       // <-- change to UNIT_LED_COLOR_GREEN/BLUE for other units

// ---- External bi-color charge-status LED (Unit C add-on) ----------------
// Optional panel-mount 3mm COMMON-CATHODE red/green LED that shows charge
// status at a glance, independent of the onboard RGB LED. Wiring:
//
//   D9  --[ 470R ]-->  RED anode      (charging)
//   D10 --[ 470R ]-->  GREEN anode    (charged / full)
//   GND ------------>  common cathode (shared)
//
// IMPORTANT: this LED is COMMON-CATHODE, so a GPIO HIGH turns a color ON —
// the OPPOSITE polarity of the onboard common-anode LED (which is LOW = ON).
// Put a 470R resistor on EACH anode leg (~2.5mA at 3.3V), not one shared
// resistor on the cathode, so the two colors stay balanced. 430R also fine;
// 330R from the assortment kit if you want it brighter (~4mA).
//
// Comment out ENABLE_EXT_CHARGE_LED to disable this and free D9/D10.
#define ENABLE_EXT_CHARGE_LED
const uint8_t EXT_LED_RED   = D9;   // charging indicator (anode, HIGH = on)
const uint8_t EXT_LED_GREEN = D10;  // charged  indicator (anode, HIGH = on)

// =========================================================================
// ==================== END SETTINGS — code below ==========================
// =========================================================================

#define PIN_BAT_READ_EN  (32 + 14)
#define PIN_VBAT_ADC     (0  + 31)
#define PIN_CHARGE_SEL   (0  + 13)

const uint32_t DEBOUNCE_MS         = 30;
const uint32_t LED_PULSE_PERIOD_MS = 1500;
// Voltage-readout timing: 80ms on / 80ms off per flash, 400ms pause
// between the integer portion and the tenths portion.
const uint32_t VR_FLASH_ON_MS      = 80;
const uint32_t VR_FLASH_OFF_MS     = 80;
const uint32_t VR_GAP_MS           = 400;

BLEDis bledis;
BLEHidAdafruit blehid;

uint32_t lastActivityMs = 0;
uint32_t lastBatCheckMs = 0;
uint32_t lastVoltageReportMs = 0;
float    lastBatV = 4.0;
uint8_t  batReadsTaken = 0;
bool     buttonPrev = HIGH;
uint32_t buttonChangeMs = 0;
uint32_t buttonDownAtMs = 0;     // press-start timestamp (for duration calc)
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
// External bi-color charge-status LED (common-cathode → HIGH = ON).
// Fully independent of the onboard RGB LED; safe to leave enabled even if
// nothing is wired to D9/D10 (it just toggles two unused GPIOs).
// =========================================================================
#ifdef ENABLE_EXT_CHARGE_LED
void extRedOn()    { digitalWrite(EXT_LED_RED,   HIGH); }
void extRedOff()   { digitalWrite(EXT_LED_RED,   LOW);  }
void extGreenOn()  { digitalWrite(EXT_LED_GREEN, HIGH); }
void extGreenOff() { digitalWrite(EXT_LED_GREEN, LOW);  }
void extOff()      { extRedOff(); extGreenOff(); }

// Drive the external charge LED from USB-present + cell voltage:
//   charging (USB, V < full)  -> solid RED
//   charged  (USB, V >= full) -> solid GREEN
//   on battery, critical      -> blinking RED (low-battery alarm)
//   on battery, healthy       -> OFF (so the LED never drains the cell)
void updateChargeLed(uint32_t now) {
  if (usbPowered()) {
    if (lastBatV >= BAT_FULL_V) { extGreenOn(); extRedOff(); }
    else                        { extRedOn();   extGreenOff(); }
    return;
  }
  if (lastBatV < BAT_CRITICAL_V) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) extRedOn(); else extRedOff();
    extGreenOff();
    return;
  }
  extOff();
}
#endif

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
// Sequence only runs while the button is released (we don't want the
// status LED hijacking the live press-duration feedback during a press).
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

  #ifdef ENABLE_EXT_CHARGE_LED
    pinMode(EXT_LED_RED,   OUTPUT);
    pinMode(EXT_LED_GREEN, OUTPUT);
    extOff();
  #endif

  pinMode(PIN_BAT_READ_EN, OUTPUT);
  digitalWrite(PIN_BAT_READ_EN, HIGH);

  analogReference(AR_INTERNAL_3_0);
  analogReadResolution(12);

  // ---- Boot-time battery check ----
  // Take a few readings to let the ADC settle, then act on the average.
  // (No UVLO shutdown — low battery is indicated by the status LED only.)
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

  // ---- Boot indication: R → A → G sequence ----
  // Teaches the user the duration zones at startup.
  ledRedOn();   delay(150); ledAllOff(); delay(80);
  ledAmberOn(); delay(150); ledAllOff(); delay(80);
  ledGreenOn(); delay(150); ledAllOff();

  // ---- BLE init ----
  Bluefruit.begin();
  Bluefruit.setTxPower(4);
  Bluefruit.setName(DEVICE_NAME);
  Bluefruit.Security.setIOCaps(false, false, false);

  Bluefruit.Periph.setConnectCallback(onConnect);
  Bluefruit.Periph.setDisconnectCallback(onDisconnect);

  bledis.setManufacturer("Open Adaptive Switch");
  bledis.setModel("Unit C (multi-mode)");
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

  // Button — detect press AND release; the duration between determines key.
  bool b = digitalRead(PIN_BUTTON);
  if (b != buttonPrev && (now - buttonChangeMs) > DEBOUNCE_MS) {
    buttonChangeMs = now;
    buttonPrev = b;
    if (b == LOW) {                       // press start
      buttonDownAtMs = now;
      vrState = VR_IDLE;                  // abort any voltage readout in flight
      ledRedOn();                         // immediate red = "short zone"
      lastActivityMs = now;
    } else {                              // release — fire the key
      uint32_t heldMs = now - buttonDownAtMs;
      ledAllOff();
      onButtonReleased(heldMs);
      lastActivityMs = now;
    }
  }

  // Live duration feedback WHILE held — color tracks the active zone.
  if (buttonPrev == LOW) {
    uint32_t heldMs = now - buttonDownAtMs;
    if      (heldMs < SHORT_PRESS_MAX_MS)  { ledRedOn();   ledGreenOff(); }
    else if (heldMs < MEDIUM_PRESS_MAX_MS) { ledAmberOn();                }
    else                                   { ledRedOff();  ledGreenOn();  }
  }

  // Periodic battery check — only updates the LED indicator, no shutdown.
  if (now - lastBatCheckMs > BAT_CHECK_MS) {
    lastBatCheckMs = now;
    lastBatV = readBatteryVoltage();
  }

  // External charge LED runs every loop, independent of button state and
  // the onboard LED, so charge status is always visible.
  #ifdef ENABLE_EXT_CHARGE_LED
    updateChargeLed(now);
  #endif

  // Idle-only visuals: voltage readout + status LED. Run ONLY when the
  // button is released, otherwise they would overwrite the live
  // duration-zone feedback above.
  if (buttonPrev == HIGH) {
    // Kick off the voltage readout every BAT_REPORT_MS when nothing else
    // is using the LED (state machine idle).
    if (vrState == VR_IDLE && (now - lastVoltageReportMs) > BAT_REPORT_MS) {
      lastVoltageReportMs = now;
      startVoltageReport(lastBatV);
    }
    advanceVoltageReport(now);
    updateStatusLed(now);
  }

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
// Fire the HID key matching the duration the button was held for, then
// flash a confirmation color in the same zone.
// =========================================================================
void onButtonReleased(uint32_t heldMs) {
  uint8_t key;
  if      (heldMs < SHORT_PRESS_MAX_MS)  key = KEY_SHORT;
  else if (heldMs < MEDIUM_PRESS_MAX_MS) key = KEY_MEDIUM;
  else                                   key = KEY_LONG;

  if (isConnected) {
    blehid.keyPress(key);
    delay(15);
    blehid.keyRelease();
  }

  // Confirmation flash in the matching zone color
  if      (key == KEY_SHORT)  { ledRedOn();   delay(80); ledRedOff();   }
  else if (key == KEY_MEDIUM) { ledAmberOn(); delay(80); ledAllOff();   }
  else                        { ledGreenOn(); delay(80); ledGreenOff(); }
}

// =========================================================================
// Idle status LED (only called while the button is released).
// Priority order (highest → lowest):
//   1. Voltage-readout state machine is running (its own LED control).
//   2. Critical battery: blink red (safety — wins over charging).
//   3. USB power present + cell not full: purple pulse (charging).
//   4. Low battery (and not charging): solid red.
//   5. Advertising (not paired): pulse accent (red for unit C).
//   6. Connected, idle: off.
// =========================================================================
void updateStatusLed(uint32_t now) {
  // 1. Voltage report owns the LED while running.
  if (vrState != VR_IDLE) return;

  // 2. Critical battery wins regardless of charging.
  if (lastBatV < BAT_CRITICAL_V) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledRedOn(); else ledRedOff();
    ledGreenOff(); ledBlueOff();
    return;
  }

  // 3. Charging — purple pulse whenever USB is present and the cell hasn't
  //    reached full. Even if the onboard orange CHG LED isn't visible/wired,
  //    this is firmware-side confirmation that USB power has reached the
  //    chip. If the cell voltage isn't climbing across successive 30s
  //    readouts despite this pulsing, the cell-to-BAT-pad path is broken.
  if (usbPowered() && lastBatV < BAT_FULL_V) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledPurpleOn(); else ledAllOff();
    return;
  }

  // 4. Low battery, not charging.
  if (lastBatV < BAT_LOW_V) {
    ledRedOn();
    ledGreenOff(); ledBlueOff();
    return;
  }

  // 5. Advertising — pulse accent.
  if (!isConnected) {
    bool on = (now / (LED_PULSE_PERIOD_MS / 2)) % 2 == 0;
    if (on) ledAccentOn(); else ledAccentOff();
    return;
  }

  // 6. Connected idle.
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
