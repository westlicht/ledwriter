
//
// LED writer application 0.1
//
// by Simon Kallweit <simon@weirdsot.ch>
//
// written for Arduino 0017
//
// Arduino Stamp is used for the LED writer application with the following
// pin connections:
//
// Pin 2-9: LEDs
// Pin 10: Key (SLOWER)
// Pin 11; Key (MODE)
// Pin 12: Key (FASTER)
//
// The software is controlled with the following key commands:
//
// MODE - resets the current mode
// MODE (hold) switches the LED writer mode
// SLOWER - decreases frequency
// FASTER - increases frequency
// MODE (hold) + SLOWER - decreases LED hold time (0 = indefinitly)
// MODE (hold) + FASTER - increases LED hold time
//
// Currently the following modes are implemented:
//
// Off - LEDs are always off
// On - LEDs are always on
// Blink - LEDs are blinking
// Ramp - LEDs are enabled one by one in a row
// Ping Ping - LEDs are enabled in a ping-pong fashion
// Random Single - LEDs are enabled randomly (one at a time)
// Random Multi - LEDs are enabled randomly (multiple LEDs at a time)
// Scroll - LEDs are enabled based on a scrolling text
//

#include <avr/pgmspace.h>

#define DEBUG

#ifdef DEBUG
# define DBG(_text_) Serial.println(_text_)
#else
# define DBG(_text_)
#endif

//
// Configuration
//

const int led_pins[] = { 2, 3, 4, 5, 6, 7, 8, 9 };
const int key_pins[] = { 10, 11, 12 };

#define KEY_SLOWER         0
#define KEY_FASTER         2
#define KEY_MODE           1

#define KEY_DEBOUNCE       5                // Debounce time in ms
#define KEY_REPEAT         200              // Key repeat time in ms
#define VELOCITY_RANGE     100              // Speed range +/- percent
#define MAX_HOLD_TIME      100              // Maximum LED hold time
                                           
#define FONT_HEIGHT        8                // Font height in pixels
#define FONT_SPACING       1                // Font spacing in pixels
#define SCROLL_TEXT_LEN    100              // Max length of scroll text

//
// Globals
//

static int mode = 7;                        // Current mode
static int velocity = 0;                    // Current speed
static int hold_time = 0;                   // Current hold time in ms
static unsigned long index;                 // Current index
static unsigned long last_time;             // Last tick time

static char scroll_text[SCROLL_TEXT_LEN];   // Scroll text
static int scroll_index;                    // Current scroll char index
static char scroll_char;                    // Current scroll char
static int scroll_len;                      // Current scroll char len
static int scroll_row;                      // Current scroll char row index

//
// Modes
//

typedef void (*mode_handler_t)(void);

struct mode_info {
  mode_handler_t reset;
  mode_handler_t tick;
  unsigned long interval;
};

static struct mode_info mode_infos[] = {
  { NULL, mode_off_tick, 1000 },
  { NULL, mode_on_tick, 1000 },
  { NULL, mode_blink_tick, 100 },
  { NULL, mode_ramp_tick, 100 },
  { NULL, mode_ping_pong_tick, 100 },
  { NULL, mode_random_single_tick, 100 },
  { NULL, mode_random_multi_tick, 100 },
  { mode_scroll_reset, mode_scroll_tick, 20 },
};

#define NUM_MODES (sizeof(mode_infos) / sizeof(mode_infos[0]))

//
// LED handling
//

#define NUM_LEDS (sizeof(led_pins) / sizeof(led_pins[0]))

// Setup LED pins.
void led_setup(void)
{
  for (int i = 0; i < NUM_LEDS; i++)
    pinMode(led_pins[i], OUTPUT);
}

// Writes a bit pattern to the LED pins.
void led_write(int state)
{
  for (int i = 0; i < NUM_LEDS; i++)
    digitalWrite(led_pins[i], (state & (1 << i)) ? HIGH : LOW);
}

//
// Key handling
//

#define NUM_KEYS (sizeof(key_pins) / sizeof(key_pins[0]))

static unsigned long key_last[NUM_KEYS];
static byte key_state[NUM_KEYS];

typedef enum {
  NAV_MODE_UNLOCKED,
  NAV_MODE_LOCKED,
} nav_state_t;

static nav_state_t nav_state = NAV_MODE_UNLOCKED;

// Setup key pins.
void key_setup(void)
{
  for (int i = 0; i < NUM_KEYS; i++) {
    pinMode(key_pins[i], INPUT);
    key_last[i] = millis();
    key_state[i] = LOW;
  }
}

// Called when a key was pressed/released.
void key_handler(int key, int state, int repeated)
{
#ifdef DEBUG
  Serial.print("key handler key=");
  Serial.print(key, DEC);
  Serial.print(" state=");
  Serial.print(state, DEC);
  Serial.print(" repeated=");
  Serial.println(repeated, DEC);
#endif
  
  switch (nav_state) {
  case NAV_MODE_UNLOCKED:
    if (key == KEY_MODE && state == HIGH && repeated == 0) {
      DBG("reset");
      mode_reset();
    } else if (key == KEY_MODE && state == HIGH && repeated == 3) {
      DBG("switch mode");
      mode = (mode + 1) % NUM_MODES;
      mode_reset();
    } else if (key == KEY_SLOWER && state == HIGH && key_state[KEY_MODE] == HIGH) {
      if (hold_time > 0)
        hold_time--;
      nav_state = NAV_MODE_LOCKED;
    } else if (key == KEY_FASTER && state == HIGH && key_state[KEY_MODE] == HIGH) {
      if (hold_time < MAX_HOLD_TIME)
        hold_time++;
      nav_state = NAV_MODE_LOCKED;
    } else if (key == KEY_SLOWER && state == HIGH) {
      if (velocity > -VELOCITY_RANGE)
        velocity--;
    } else if (key == KEY_FASTER && state == HIGH) {
      if (velocity < VELOCITY_RANGE)
        velocity++;
    }
    break;
  case NAV_MODE_LOCKED:
    if (key == KEY_MODE && state == LOW) {
        nav_state = NAV_MODE_UNLOCKED;
    } else if (key == KEY_SLOWER && state == HIGH) {
      if (hold_time > 0)
        hold_time--;
      nav_state = NAV_MODE_LOCKED;
    } else if (key == KEY_FASTER && state == HIGH) {
      if (hold_time < MAX_HOLD_TIME)
        hold_time++;
      nav_state = NAV_MODE_LOCKED;
    }
    break;
  }
}

// Check keys, do debouncing and detect repeated keys.
// Invokes keys_handler() when key has been pressed/released.
void key_loop(void)
{
  static int repeated[NUM_KEYS];
  for (int i = 0; i < NUM_KEYS; i++) {
    if (millis() < key_last[i] + KEY_DEBOUNCE)
      continue;
    byte state = digitalRead(key_pins[i]);
    if (state != key_state[i]) {
      repeated[i] = 0;
      key_handler(i, state, repeated[i]);
      key_state[i] = state;
      key_last[i] = millis();
    } else if ((state == HIGH) && (millis() > key_last[i] + KEY_REPEAT)) {
      // Repeated key
      key_handler(i, state, ++repeated[i]);
      key_last[i] = millis();
    }
  }
}

//
// Menu handling
//

void menu_setup(void)
{
  Serial.begin(9600);
  Serial.println("LED Writer 0.1 - by Simon Kallweit 2010");
}

void menu_loop(void)
{
  return;
  while (Serial.available() > 0) {
    char c = Serial.read();
  }
}

//
// Mode handlers
//

void mode_setup(void)
{
  mode_reset();
}

void mode_loop(void)
{
  unsigned long interval = mode_infos[mode].interval;
  interval -= ((interval * velocity) / 100);
  while (millis() - last_time >= interval) {
    last_time += interval;
    mode_infos[mode].tick();
  }
  if ((hold_time > 0) && (millis() - last_time > hold_time)) {
    led_write(0);
  }
}

void mode_reset(void)
{
  index = 0;
  last_time = millis();
  if (mode_infos[mode].reset)
    mode_infos[mode].reset();
  mode_infos[mode].tick();
}

void mode_off_tick(void)
{
  led_write(0x00);
}

void mode_on_tick(void)
{
  led_write(0xff);
}

void mode_blink_tick(void)
{
  led_write(index % 2 == 0 ? 0x00 : 0xff);
  index++;
}

void mode_ramp_tick(void)
{
  led_write(1 << index);
  index = (index + 1) % NUM_LEDS;
}

void mode_ping_pong_tick(void)
{
  led_write(index < NUM_LEDS ? 1 << index : 1 << (NUM_LEDS * 2 - index - 2));
  index = (index + 1) % (NUM_LEDS * 2 - 2);
}

void mode_random_single_tick(void)
{
  led_write(1 << random(NUM_LEDS));
}

void mode_random_multi_tick(void)
{
  led_write(random(0xffff));
}

void mode_scroll_reset(void)
{
  scroll_index = 0;
  scroll_char = scroll_text[scroll_index];
  scroll_len = font_char_len(scroll_char) + FONT_SPACING;
  scroll_row = 0;
}

void mode_scroll_tick(void)
{
  if (scroll_char == '\0')
    return;
  // Fetch next character
  while (scroll_row >= scroll_len) {
    scroll_index++;
    if (scroll_index >= sizeof(scroll_text))
      return;
    scroll_char = scroll_text[scroll_index];
    if (scroll_char == '\0')
      return;
    scroll_len = font_char_len(scroll_char) + FONT_SPACING;
    scroll_row = 0;
  }
  
#ifdef DEBUG_
  Serial.print(scroll_index, DEC);
  Serial.print(" ");
  Serial.print(scroll_char, BYTE);
  Serial.print(" ");
  Serial.print(scroll_row, DEC);
  Serial.print(" ");
  Serial.print(scroll_len, DEC);
  Serial.println("");
#endif
  
  int row = font_char_row(scroll_char, scroll_row);
#ifdef DEBUG
  for (int i = 0; i < 8; i++) {
    Serial.print(row & (1 << i) ? 'x' : ' ', BYTE);
  }
  Serial.println("");
#endif
  led_write(row << ((NUM_LEDS - FONT_HEIGHT) / 2));
  scroll_row++;
}

//
// Main application
//

void setup(void)
{
  led_setup();
  key_setup();
  menu_setup();
  mode_setup();
  
  strncpy(scroll_text, "ORLANDO MENTHOL",  sizeof(scroll_text));
}

void loop(void)
{
  key_loop();
//  menu_loop();
  mode_loop();
}

