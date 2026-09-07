#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads Apple Silicon temperature sensors via the IOHID thermal sensor hub.
/// Returns a map of raw sensor name (e.g. "PMU tdev1", "gas gauge battery") to
/// value in degrees Celsius. Works on M1–M5. Returns an empty dictionary if the
/// sensor hub is unavailable.
NSDictionary<NSString *, NSNumber *> *PHUDReadTemperatureSensors(void);

/// Reads fan speeds via the SMC. Returns a map of fan label (e.g. "Fan 1") to
/// current RPM. Fan RPM SMC keys (F0Ac, F1Ac, …) are stable across Mac models,
/// unlike temperature keys. Returns an empty dictionary on machines with no fans
/// (e.g. MacBook Air) or if the SMC is unavailable.
NSDictionary<NSString *, NSNumber *> *PHUDReadFanSpeeds(void);

/// Reads power delivery via the SMC, in watts. Possible keys:
///   "in"     — power coming in from the adapter (SMC PDTR); 0 on battery.
///   "system" — total power the machine is drawing (SMC PSTR).
/// A key is omitted when the machine doesn't expose it (desktop Macs have no
/// "in") or the reading is out of range. Empty if the SMC is unavailable.
NSDictionary<NSString *, NSNumber *> *PHUDReadPower(void);

/// Per-block SoC power, in watts, from the IOReport "Energy Model" group — the
/// same counters `powermetrics` reports, but readable without root.
///
/// Only whole-SoC blocks are exposed by the hardware; there is no per-process or
/// per-USB-device attribution to be had (see README). Create one reader and hold
/// onto it: watts come from the delta between consecutive samples.
@interface PHUDSoCPowerReader : NSObject

/// Watts drawn per block since the previous call. Possible keys: "cpu", "gpu",
/// "ane", "dram", "dramController", "systemCache", "fabric", "displayEngine",
/// "displayExternal", "isp", "videoEncoder", "msr", "afr", "pcie". A key is
/// omitted when this Mac doesn't expose that counter. The first call primes the
/// counters and returns an empty dictionary, as does any call on a machine where
/// IOReport is unavailable.
- (NSDictionary<NSString *, NSNumber *> *)sample;

@end

/// Reads per-core temperatures from the SMC. The IOHID thermal hub only exposes
/// generic die-area sensors ("PMU tdieN") that run 15–20 °C cooler than the real
/// hot spots; the SMC's "Tp"/"Tg" keys are the per-core sensors Macs Fan Control
/// shows. Key names are enumerated once at init, so sampling stays cheap.
@interface PHUDTemperatureReader : NSObject

/// CPU core temperatures in °C (SMC "Tp" keys).
- (NSArray<NSNumber *> *)cpuCoreTemperatures;
/// GPU temperatures in °C (SMC "Tg" keys).
- (NSArray<NSNumber *> *)gpuTemperatures;

@end

/// How hard a CPU cluster or the GPU is clocking, from IOReport's DVFS residency
/// histograms ("CPU Core Performance States" / "GPU Performance States").
@interface PHUDClockState : NSObject
/// Share of the sampling window spent in a running state rather than idle, 0–100.
@property (nonatomic, readonly) double activePercent;
/// Residency-weighted position in the DVFS ladder while running, 0–100, where
/// 100 is the top state. Absolute MHz isn't derivable: the frequency tables in
/// the device tree store clock *periods* in an undocumented unit, with no
/// on-device anchor to convert them (see README).
@property (nonatomic, readonly) double clockPercent;
/// Physical cores in this cluster, used to match it against `hw.perflevelN`.
@property (nonatomic, readonly) NSInteger coreCount;
@end

/// Reads DVFS residency. Like the power reader, watts-per-second style figures
/// come from the delta between samples, so create one and hold onto it.
@interface PHUDClockReader : NSObject

/// Keyed by cluster name ("PCPU", "MCPU0", …) plus "GPU". The first call primes
/// the counters and returns an empty dictionary, as does any call on a machine
/// where IOReport is unavailable.
- (NSDictionary<NSString *, PHUDClockState *> *)sample;

@end

NS_ASSUME_NONNULL_END
