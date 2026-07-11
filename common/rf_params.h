/*
 * rf_params.h — Shared RF parameters for SDR_Link TX and RX
 *
 * Both the Zedboard (TX) and Pluto+ (RX) include this file so they
 * always agree on frequency, sample rate, etc.
 *
 * ── Why 433.920 MHz? ────────────────────────────────────────────────────────
 *
 *   The ISM band at 433-434 MHz is licence-free across Europe (ETSI EN 300 220).
 *   It's also nearly perfect for 20 cm telescoping antennas:
 *
 *     Quarter-wave length = c / (4 × f) = 3×10⁸ / (4 × 433.92×10⁶) ≈ 17.3 cm
 *
 *   Your 20 cm antenna is close enough — it's slightly long (electrically
 *   ~5/16 wave), presenting a small capacitive reactance, but the AD9361's
 *   50-ohm port tolerates the mismatch with only a dB or two of loss.
 *
 * ── Why 2.304 Msps? ─────────────────────────────────────────────────────────
 *
 *   AD9361 minimum stable sample rate is ~2.083 Msps.  2.304 Msps is a
 *   convenient multiple of common audio and data rates and matches our ACARS
 *   receiver, so we reuse that same decimation chain knowledge.
 */

#ifndef RF_PARAMS_H
#define RF_PARAMS_H

/* ── Radio parameters ───────────────────────────────────────────────────── */

#define CARRIER_FREQ_HZ   433920000LL   /* 433.92 MHz  ISM band              */
#define SAMPLE_RATE_HZ    2304000LL     /* 2.304 Msps  AD9361 minimum range  */
#define RF_BANDWIDTH_HZ    400000LL     /* 400 kHz — LPF edge at ±200 kHz   */

/*
 * TX attenuation: AD9361 TX output power is set by a hardware attenuator.
 * 0 dB = maximum power (~+4 dBm into 50 Ω).
 * We use -20 dB for indoor lab use — no need to blast the neighbours.
 *
 * How to think about it: -20 dB attenuation means 1/100th of the power,
 * so roughly +4 dBm − 20 dB = −16 dBm ≈ 25 µW at the SMA port.
 */
#define TX_ATTENUATION_MDB  20000       /* millidB — AD9361 attr unit        */

/*
 * DDS tone offset from the LO.
 * The LO sits at CARRIER_FREQ_HZ.  The DDS shifts the tone by this amount
 * so the transmitted signal is at CARRIER_FREQ_HZ + DDS_TONE_OFFSET_HZ.
 *
 * Using a 100 kHz offset keeps the tone well away from the DC spike that
 * appears at exactly 0 Hz offset (a known AD9361 artefact).
 * So TX tone = 433.920 + 0.100 = 434.020 MHz.
 * RX must tune its LO to the same 434.020 MHz.
 */
#define DDS_TONE_OFFSET_HZ  100000LL   /* 100 kHz above LO                  */

/* Resulting over-the-air frequency: */
#define TONE_FREQ_HZ   (CARRIER_FREQ_HZ + DDS_TONE_OFFSET_HZ)  /* 434.02 MHz */

/* ── OOK data link parameters (must match on TX and RX) ────────────────── */
/*
 * Bit period: how long each 0/1 is held on the carrier.
 * 100 ms/bit = 10 bps.  One RX buffer = 10 ms, so there are
 * exactly 10 buffers per bit — plenty of margin.
 */
#define OOK_BIT_PERIOD_US   100000          /* µs — 100 ms per bit           */
#define OOK_BIT_PERIOD_BUF  10              /* buffers per bit (10 ms/buf)   */
#define OOK_HALF_BIT_BUF    5               /* half-period for start centering*/
#define OOK_THRESHOLD_DBFS  (-55.0f)        /* decision level: noise≈-78, sig≈-37 */
#define OOK_MESSAGE         "HELLO SDR\n"   /* message TX loops forever      */

/* ── FSK data link parameters (must match on TX and RX) ────────────────── */
/*
 * 2-FSK tones — both above LO to avoid the DC (LO-leakage) spike:
 *
 *   MARK  (bit '1') : LO + 150 kHz  →  434.070 MHz over the air
 *   SPACE (bit '0') : LO +  50 kHz  →  433.970 MHz over the air
 *
 * Both fall within the 400 kHz passband (LPF edge at ±200 kHz).
 * Tone spacing = 100 kHz.  Bin width at 2.304 Msps / 23040 = 100 Hz,
 * so both tones land on exact DFT bins → zero spectral leakage in Goertzel.
 *
 * RX LO = CARRIER_FREQ_HZ (433.920 MHz, same as TX LO).
 * After down-conversion: MARK at 150 kHz baseband, SPACE at 50 kHz baseband.
 */
#define FSK_TONE_MARK_HZ     150000LL   /* bit '1' MARK  : 150 kHz above LO  */
#define FSK_TONE_SPACE_HZ     50000LL   /* bit '0' SPACE :  50 kHz above LO  */
#define FSK_BIT_PERIOD_US     20000     /* 20 ms/bit = 50 bps                 */
#define FSK_BIT_PERIOD_BUF        2     /* 2 × 10 ms buffers per bit          */
#define FSK_HALF_BIT_BUF          1     /* 1 buffer: start-bit centering      */
#define FSK_MIN_IDLE_BUF          2     /* min MARK buffers before start bit  */
#define FSK_MESSAGE         OOK_MESSAGE /* same content, 10× faster rate      */

/* ── IIO device names (same on Zedboard and Pluto+) ────────────────────── */
#define PHY_DEVICE      "ad9361-phy"          /* controls LO, gain, filters  */
#define TX_DDS_DEVICE   "cf-ad9361-dds-core-lpc" /* FPGA DDS — tone output   */
#define RX_DEVICE       "cf-ad9361-lpc"       /* FPGA ADC capture            */

#endif /* RF_PARAMS_H */
