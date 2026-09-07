#import "SensorBridge.h"
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>

#pragma mark - IOHID thermal sensor hub (temperatures)

// Private-but-stable IOHID SPI. These symbols live in the IOKit framework binary
// but are not exposed in the public headers, so we declare them ourselves. This
// is the same path used by tools like Hot and macos-temperature-sensor, and it is
// what Macs Fan Control reads on Apple Silicon.
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef _Nullable IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef _Nullable IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern IOHIDEventRef _Nullable IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

// IOHID event type for temperature and its field base. IOHIDEventFieldBase(type)
// is defined as (type << 16).
#define kIOHIDEventTypeTemperature 15
#define kIOHIDEventFieldTemperatureLevel (kIOHIDEventTypeTemperature << 16)

// Matching keys for the primary usage page/usage of the temperature sensors.
#define kHIDPage_AppleVendor 0xff00
#define kHIDUsage_AppleVendor_TemperatureSensor 0x0005

static CFDictionaryRef PHUDCreateTemperatureMatch(void) {
    int page = kHIDPage_AppleVendor;
    int usage = kHIDUsage_AppleVendor_TemperatureSensor;

    CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);

    CFStringRef keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    CFNumberRef values[2] = { pageNum, usageNum };

    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault,
                                               (const void **)keys,
                                               (const void **)values,
                                               2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFRelease(pageNum);
    CFRelease(usageNum);
    return match;
}

// Every call into the hub is a mach round trip to the HID event system, so the
// shape of the sweep dominates this app's cost. An M-series Mac matches ~77
// services, of which only ~53 ever return a plausible reading — the "PMU tdev*"
// group is permanently parked around −9200 °C — and those 53 share only ~17
// distinct `Product` names. Enumerating and filtering on every sample therefore
// spent 154 round trips to produce 17 numbers.
//
// So the client, the surviving services and their names are resolved once and
// cached; a sample is then one CopyEvent per live sensor. The cache is rebuilt
// periodically because the set does change when hardware comes and goes (an
// external display or the battery gauge dropping out).
#define kPHUDSensorCacheLifetime 60.0

static IOHIDEventSystemClientRef gTempClient;
/// Services that returned a usable reading when last enumerated (retained).
static CFMutableArrayRef gTempServices;
/// `Product` name per entry in `gTempServices`, index-aligned.
static NSArray<NSString *> *gTempNames;
static CFAbsoluteTime gTempCacheStamp;

static void PHUDRefreshTemperatureServices(void) {
    if (gTempClient == NULL) {
        gTempClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (gTempClient == NULL) return;
        CFDictionaryRef match = PHUDCreateTemperatureMatch();
        IOHIDEventSystemClientSetMatching(gTempClient, match);
        CFRelease(match);
    }

    CFArrayRef services = IOHIDEventSystemClientCopyServices(gTempClient);
    if (services == NULL) return;

    CFMutableArrayRef live = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    NSMutableArray<NSString *> *names = [NSMutableArray array];

    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (service == NULL) continue;

        CFStringRef name = (CFStringRef)IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (name == NULL) continue;

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        BOOL usable = NO;
        if (event != NULL) {
            double temp = IOHIDEventGetFloatValue(event, kIOHIDEventFieldTemperatureLevel);
            usable = (temp > 0.0 && temp < 200.0);
            CFRelease(event);
        }
        if (usable) {
            // kCFTypeArrayCallBacks retains, so the service outlives `services`.
            CFArrayAppendValue(live, service);
            [names addObject:(__bridge NSString *)name];
        }
        CFRelease(name);
    }
    CFRelease(services);

    if (gTempServices != NULL) CFRelease(gTempServices);
    gTempServices = live;
    gTempNames = names;
    gTempCacheStamp = CFAbsoluteTimeGetCurrent();
}

NSDictionary<NSString *, NSNumber *> *PHUDReadTemperatureSensors(void) {
    if (gTempServices == NULL ||
        CFAbsoluteTimeGetCurrent() - gTempCacheStamp > kPHUDSensorCacheLifetime) {
        PHUDRefreshTemperatureServices();
    }

    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
    if (gTempServices == NULL) return result;

    // Several services report the same `Product` — "PMU tdie1" appears four
    // times, one per die area. They are genuinely distinct sensors, so average
    // them into the single row that name gets, rather than letting whichever
    // happened to come last in an unordered list silently win.
    NSMutableDictionary<NSString *, NSNumber *> *sums = [NSMutableDictionary dictionary];
    NSCountedSet<NSString *> *counts = [NSCountedSet set];

    CFIndex count = CFArrayGetCount(gTempServices);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gTempServices, i);
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        if (event == NULL) continue;
        double temp = IOHIDEventGetFloatValue(event, kIOHIDEventFieldTemperatureLevel);
        CFRelease(event);
        if (temp <= 0.0 || temp >= 200.0) continue;

        NSString *name = gTempNames[i];
        sums[name] = @(sums[name].doubleValue + temp);
        [counts addObject:name];
    }

    for (NSString *name in sums) {
        result[name] = @(sums[name].doubleValue / [counts countForObject:name]);
    }
    return result;
}

#pragma mark - SMC (fan RPM)

// Minimal SMC reader. Only used for fan RPM, whose keys (FNum, F0Ac, F1Ac, …) are
// stable across Mac models — unlike temperature keys, which change per SoC.

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    UInt16 release;
} SMCKeyDataVers_t;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCKeyDataPLimitData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCKeyDataKeyInfo_t;

typedef struct {
    UInt32 key;
    SMCKeyDataVers_t vers;
    SMCKeyDataPLimitData_t pLimitData;
    SMCKeyDataKeyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    char bytes[32];
} SMCKeyData_t;

enum {
    kSMCUserClientOpen = 0,
    kSMCUserClientClose = 1,
    kSMCHandleYPCEvent = 2,
    kSMCReadKey = 5,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo = 9,
};

static UInt32 PHUDStrToKey(const char *str) {
    return ((UInt32)str[0] << 24) | ((UInt32)str[1] << 16) | ((UInt32)str[2] << 8) | (UInt32)str[3];
}

// Decode the SMC "flt" (32-bit float) and "fpe2" (fixed-point) data types used for
// fan RPM. Returns 0 for unrecognised types.
static float PHUDDecodeSMCValue(SMCKeyData_t *val) {
    UInt32 type = val->keyInfo.dataType;
    const unsigned char *b = (const unsigned char *)val->bytes;

    // "flt " — little-endian 32-bit float.
    if (type == PHUDStrToKey("flt ") && val->keyInfo.dataSize == 4) {
        float f;
        memcpy(&f, b, 4);
        return f;
    }
    // "fpe2" — big-endian fixed point, 2 fractional bits.
    if (type == PHUDStrToKey("fpe2") && val->keyInfo.dataSize == 2) {
        UInt16 raw = ((UInt16)b[0] << 8) | (UInt16)b[1];
        return (float)(raw >> 2);
    }
    return 0.0f;
}

static kern_return_t PHUDSMCCall(io_connect_t conn, int index, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t inSize = sizeof(SMCKeyData_t);
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, index, in, inSize, out, &outSize);
}

static kern_return_t PHUDSMCReadKey(io_connect_t conn, const char *keyStr, SMCKeyData_t *out) {
    SMCKeyData_t in;
    SMCKeyData_t info;
    memset(&in, 0, sizeof(in));
    memset(&info, 0, sizeof(info));

    // Step 1: get key info (data size + type).
    in.key = PHUDStrToKey(keyStr);
    in.data8 = kSMCGetKeyInfo;
    kern_return_t r = PHUDSMCCall(conn, kSMCHandleYPCEvent, &in, &info);
    if (r != KERN_SUCCESS) return r;

    UInt32 dataSize = info.keyInfo.dataSize;
    UInt32 dataType = info.keyInfo.dataType;

    // Step 2: read the bytes. Use a fresh output struct — the read call may not
    // repopulate keyInfo, so we restore dataSize/dataType afterward for decoding.
    memset(out, 0, sizeof(*out));
    in.keyInfo.dataSize = dataSize;
    in.data8 = kSMCReadKey;
    r = PHUDSMCCall(conn, kSMCHandleYPCEvent, &in, out);
    if (r != KERN_SUCCESS) return r;

    out->keyInfo.dataSize = dataSize;
    out->keyInfo.dataType = dataType;
    return KERN_SUCCESS;
}

/// Reads a key whose size and type are already known, skipping the
/// `kSMCGetKeyInfo` probe above. A key's metadata is fixed for the life of the
/// machine, so re-probing it on every read doubles the syscall count to learn
/// something we knew at startup — and the temperature sweep is 107 keys deep.
static kern_return_t PHUDSMCReadKnownKey(io_connect_t conn, UInt32 key,
                                         UInt32 dataSize, UInt32 dataType,
                                         SMCKeyData_t *out) {
    SMCKeyData_t in;
    memset(&in, 0, sizeof(in));
    in.key = key;
    in.keyInfo.dataSize = dataSize;
    in.data8 = kSMCReadKey;

    memset(out, 0, sizeof(*out));
    kern_return_t r = PHUDSMCCall(conn, kSMCHandleYPCEvent, &in, out);
    if (r != KERN_SUCCESS) return r;

    out->keyInfo.dataSize = dataSize;
    out->keyInfo.dataType = dataType;
    return KERN_SUCCESS;
}

/// Opens a connection to the SMC user client. Returns 0 if unavailable.
static io_connect_t PHUDSMCOpen(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSMC"));
    if (service == 0) {
        return 0;
    }

    io_connect_t conn = 0;
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    return (r == KERN_SUCCESS) ? conn : 0;
}

/// The one SMC user client every reader shares. Opening and closing it per
/// sample cost a service lookup plus two IOKit round trips a second for no
/// benefit — the connection is stateless and there is no reason to hold more
/// than one. Callers must not close it.
static io_connect_t PHUDSharedSMCConnection(void) {
    static io_connect_t conn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ conn = PHUDSMCOpen(); });
    return conn;
}

/// How many fans this Mac has. Fixed hardware, so resolved once.
static int PHUDFanCount(io_connect_t conn) {
    static int fanCount = -1;
    if (fanCount >= 0) return fanCount;

    SMCKeyData_t fnum;
    fanCount = 0;
    if (PHUDSMCReadKey(conn, "FNum", &fnum) == KERN_SUCCESS) {
        fanCount = (int)PHUDDecodeSMCValue(&fnum);
        if (fanCount <= 0 || fanCount > 10) {
            // Some machines store FNum as a plain byte instead of fpe2/flt.
            fanCount = (int)fnum.bytes[0];
        }
    }
    if (fanCount <= 0 || fanCount > 10) {
        fanCount = 2; // Reasonable fallback for MacBook Pro; missing keys are skipped.
    }
    return fanCount;
}

NSDictionary<NSString *, NSNumber *> *PHUDReadFanSpeeds(void) {
    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];

    io_connect_t conn = PHUDSharedSMCConnection();
    if (conn == 0) {
        return result;
    }

    int fanCount = PHUDFanCount(conn);
    for (int i = 0; i < fanCount; i++) {
        char key[5];
        snprintf(key, sizeof(key), "F%dAc", i);
        SMCKeyData_t val;
        if (PHUDSMCReadKey(conn, key, &val) == KERN_SUCCESS) {
            float rpm = PHUDDecodeSMCValue(&val);
            if (rpm > 0.0f && rpm < 30000.0f) {
                result[[NSString stringWithFormat:@"Fan %d", i + 1]] = @(rpm);
            }
        }
    }

    return result;
}

#pragma mark - SMC (per-core temperatures)

/// The SMC's key list is index-addressed; "#KEY" holds the count.
static kern_return_t PHUDSMCKeyAtIndex(io_connect_t conn, UInt32 index, UInt32 *keyOut) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = index;
    kern_return_t r = PHUDSMCCall(conn, kSMCHandleYPCEvent, &in, &out);
    if (r == KERN_SUCCESS) *keyOut = out.key;
    return r;
}

@implementation PHUDTemperatureReader {
    io_connect_t _conn;
    NSMutableArray<NSNumber *> *_cpuKeys;   // Raw UInt32 SMC keys.
    NSMutableArray<NSNumber *> *_gpuKeys;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;

    _cpuKeys = [NSMutableArray array];
    _gpuKeys = [NSMutableArray array];
    _conn = PHUDSharedSMCConnection();
    if (_conn == 0) return self;

    // Walking all ~3700 keys is slow, so do it once here and cache the matches.
    SMCKeyData_t count;
    if (PHUDSMCReadKey(_conn, "#KEY", &count) != KERN_SUCCESS) return self;
    const unsigned char *b = (const unsigned char *)count.bytes;
    UInt32 total = ((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) | ((UInt32)b[2] << 8) | (UInt32)b[3];
    if (total == 0 || total > 10000) return self;

    for (UInt32 i = 0; i < total; i++) {
        UInt32 key = 0;
        if (PHUDSMCKeyAtIndex(_conn, i, &key) != KERN_SUCCESS) continue;
        char name[5];
        name[0] = (key >> 24) & 0xff; name[1] = (key >> 16) & 0xff;
        name[2] = (key >> 8) & 0xff;  name[3] = key & 0xff; name[4] = 0;
        if (name[0] != 'T') continue;

        // Only accept keys that actually read as a plausible temperature now, so
        // unpopulated or differently-typed sensors never reach the UI.
        SMCKeyData_t value;
        if (PHUDSMCReadKey(_conn, name, &value) != KERN_SUCCESS) continue;
        if (value.keyInfo.dataType != PHUDStrToKey("flt ") || value.keyInfo.dataSize != 4) continue;
        float temp = PHUDDecodeSMCValue(&value);
        if (!isfinite(temp) || temp <= 0.0f || temp >= 125.0f) continue;

        if (name[1] == 'p') [_cpuKeys addObject:@(key)];
        else if (name[1] == 'g') [_gpuKeys addObject:@(key)];
    }
    return self;
}

// No dealloc: the SMC connection is shared and outlives every reader.

- (NSArray<NSNumber *> *)readKeys:(NSArray<NSNumber *> *)keys {
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:keys.count];
    if (_conn == 0) return result;

    // Every cached key was verified as "flt "/4 during enumeration, so the size
    // and type are already known and each read is a single IOKit call.
    for (NSNumber *boxed in keys) {
        SMCKeyData_t value;
        if (PHUDSMCReadKnownKey(_conn, boxed.unsignedIntValue, 4,
                                PHUDStrToKey("flt "), &value) != KERN_SUCCESS) continue;
        float temp = PHUDDecodeSMCValue(&value);
        if (isfinite(temp) && temp > 0.0f && temp < 125.0f) [result addObject:@(temp)];
    }
    return result;
}

- (NSArray<NSNumber *> *)cpuCoreTemperatures { return [self readKeys:_cpuKeys]; }
- (NSArray<NSNumber *> *)gpuTemperatures { return [self readKeys:_gpuKeys]; }

@end

#pragma mark - IOReport (per-block SoC power)

// libIOReport is private but present on every Mac, and lives only in the dyld
// shared cache — so we dlopen it by path and resolve what we need. Unlike the
// powermetrics route to the same counters, this needs no root.

typedef struct __IOReportSubscription *PHUDIOReportSubscriptionRef;

static CFMutableDictionaryRef (*PHUD_IOReportCopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
static PHUDIOReportSubscriptionRef _Nullable (*PHUD_IOReportCreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
static CFDictionaryRef _Nullable (*PHUD_IOReportCreateSamples)(PHUDIOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
static CFDictionaryRef _Nullable (*PHUD_IOReportCreateSamplesDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
static void (*PHUD_IOReportIterate)(CFDictionaryRef, int (^)(CFDictionaryRef));
static CFStringRef _Nullable (*PHUD_IOReportChannelGetChannelName)(CFDictionaryRef);
static CFStringRef _Nullable (*PHUD_IOReportChannelGetUnitLabel)(CFDictionaryRef);
static int64_t (*PHUD_IOReportSimpleGetIntegerValue)(CFDictionaryRef, int);

static BOOL PHUDIOReportAvailable(void) {
    static BOOL available = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
        if (lib == NULL) return;

        PHUD_IOReportCopyChannelsInGroup = dlsym(lib, "IOReportCopyChannelsInGroup");
        PHUD_IOReportCreateSubscription = dlsym(lib, "IOReportCreateSubscription");
        PHUD_IOReportCreateSamples = dlsym(lib, "IOReportCreateSamples");
        PHUD_IOReportCreateSamplesDelta = dlsym(lib, "IOReportCreateSamplesDelta");
        PHUD_IOReportIterate = dlsym(lib, "IOReportIterate");
        PHUD_IOReportChannelGetChannelName = dlsym(lib, "IOReportChannelGetChannelName");
        PHUD_IOReportChannelGetUnitLabel = dlsym(lib, "IOReportChannelGetUnitLabel");
        PHUD_IOReportSimpleGetIntegerValue = dlsym(lib, "IOReportSimpleGetIntegerValue");

        available = PHUD_IOReportCopyChannelsInGroup && PHUD_IOReportCreateSubscription
                 && PHUD_IOReportCreateSamples && PHUD_IOReportCreateSamplesDelta
                 && PHUD_IOReportIterate && PHUD_IOReportChannelGetChannelName
                 && PHUD_IOReportChannelGetUnitLabel && PHUD_IOReportSimpleGetIntegerValue;
    });
    return available;
}

/// Which bucket an "Energy Model" channel belongs to, or nil to ignore it. The
/// group also carries per-core and per-cluster channels (PACC_n, MCPU1_3, …)
/// that are already rolled up into the totals below — counting them too would
/// double the CPU figure, so only the exact roll-up names are accepted.
///
/// Channel names are Apple's internal block abbreviations. The ones mapped to a
/// descriptive key are identified with confidence; MSR and AFR keep their raw
/// names because their exact meaning isn't documented and guessing would be
/// worse than showing the acronym.
static NSString *_Nullable PHUDSoCBucketForChannel(NSString *name) {
    if ([name isEqualToString:@"CPU Energy"]) return @"cpu";
    if ([name isEqualToString:@"GPU Energy"]) return @"gpu";
    if ([name isEqualToString:@"DRAM"]) return @"dram";
    // Named "ANE" on some SoCs, "ANE0 Energy" on others.
    if ([name isEqualToString:@"ANE"] || ([name hasPrefix:@"ANE"] && [name hasSuffix:@"Energy"])) return @"ane";

    if ([name isEqualToString:@"DCS"]) return @"dramController";
    if ([name isEqualToString:@"AMCC"]) return @"systemCache";
    if ([name isEqualToString:@"FAB"]) return @"fabric";
    if ([name isEqualToString:@"DISP"]) return @"displayEngine";
    if ([name isEqualToString:@"DISPEXT"]) return @"displayExternal";
    if ([name isEqualToString:@"ISP"]) return @"isp";
    if ([name isEqualToString:@"AVE"]) return @"videoEncoder";
    if ([name isEqualToString:@"MSR"]) return @"msr";
    if ([name isEqualToString:@"AFR"]) return @"afr";
    // Several PCIe channels ("PCIe Port 0 Energy", "apciec1 Energy", …) roll up.
    if ([name hasPrefix:@"PCIe"] || [name hasPrefix:@"apciec"]) return @"pcie";
    return nil;
}

/// Energy counters come in whatever unit the block reports (nJ on the GPU, mJ on
/// the CPU, …), so normalise to joules before dividing by elapsed time.
static double PHUDJoulesPerUnit(NSString *_Nullable unit) {
    NSString *u = [unit stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([u isEqualToString:@"J"]) return 1.0;
    if ([u isEqualToString:@"mJ"]) return 1e-3;
    if ([u isEqualToString:@"uJ"] || [u isEqualToString:@"µJ"]) return 1e-6;
    if ([u isEqualToString:@"nJ"]) return 1e-9;
    if ([u isEqualToString:@"pJ"]) return 1e-12;
    return 0.0; // Unknown unit — better to drop the channel than to invent a scale.
}

@implementation PHUDSoCPowerReader {
    CFMutableDictionaryRef _channels;
    PHUDIOReportSubscriptionRef _subscription;
    CFDictionaryRef _previous;
    CFAbsoluteTime _previousTime;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    if (!PHUDIOReportAvailable()) return self;

    CFMutableDictionaryRef channels = PHUD_IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (channels == NULL) return self;

    CFMutableDictionaryRef subscribed = NULL;
    PHUDIOReportSubscriptionRef sub = PHUD_IOReportCreateSubscription(NULL, channels, &subscribed, 0, NULL);
    CFRelease(channels);
    if (sub == NULL) {
        if (subscribed != NULL) CFRelease(subscribed);
        return self;
    }
    _channels = subscribed;
    _subscription = sub;
    return self;
}

- (void)dealloc {
    if (_previous != NULL) CFRelease(_previous);
    if (_channels != NULL) CFRelease(_channels);
    if (_subscription != NULL) CFRelease(_subscription);
}

- (NSDictionary<NSString *, NSNumber *> *)sample {
    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
    if (_subscription == NULL || _channels == NULL) return result;

    CFDictionaryRef current = PHUD_IOReportCreateSamples(_subscription, _channels, NULL);
    if (current == NULL) return result;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    CFDictionaryRef previous = _previous;
    CFAbsoluteTime elapsed = now - _previousTime;
    _previous = current;
    _previousTime = now;

    // First call has nothing to diff against; it just primes the counters.
    if (previous == NULL) return result;

    if (elapsed > 0) {
        CFDictionaryRef delta = PHUD_IOReportCreateSamplesDelta(previous, current, NULL);
        if (delta != NULL) {
            PHUD_IOReportIterate(delta, ^int(CFDictionaryRef channel) {
                NSString *name = (__bridge NSString *)PHUD_IOReportChannelGetChannelName(channel);
                NSString *bucket = name ? PHUDSoCBucketForChannel(name) : nil;
                if (bucket == nil) return 0;

                double scale = PHUDJoulesPerUnit((__bridge NSString *)PHUD_IOReportChannelGetUnitLabel(channel));
                if (scale == 0.0) return 0;

                double watts = (double)PHUD_IOReportSimpleGetIntegerValue(channel, 0) * scale / elapsed;
                if (isfinite(watts) && watts >= 0.0 && watts < 1000.0) {
                    result[bucket] = @(result[bucket].doubleValue + watts);
                }
                return 0; // Keep iterating.
            });
            CFRelease(delta);
        }
    }

    CFRelease(previous);
    return result;
}

@end

#pragma mark - IOReport (DVFS residency)

static int32_t (*PHUD_IOReportStateGetCount)(CFDictionaryRef);
static CFStringRef _Nullable (*PHUD_IOReportStateGetNameForIndex)(CFDictionaryRef, int32_t);
static int64_t (*PHUD_IOReportStateGetResidency)(CFDictionaryRef, int32_t);

static BOOL PHUDIOReportStateAvailable(void) {
    static BOOL available = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!PHUDIOReportAvailable()) return;
        void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
        if (lib == NULL) return;
        PHUD_IOReportStateGetCount = dlsym(lib, "IOReportStateGetCount");
        PHUD_IOReportStateGetNameForIndex = dlsym(lib, "IOReportStateGetNameForIndex");
        PHUD_IOReportStateGetResidency = dlsym(lib, "IOReportStateGetResidency");
        available = PHUD_IOReportStateGetCount && PHUD_IOReportStateGetNameForIndex
                 && PHUD_IOReportStateGetResidency;
    });
    return available;
}

/// States that mean "not running": the cluster is idle or powered down. Every
/// other state is a rung on the DVFS ladder, ordered slowest to fastest.
static BOOL PHUDIsIdleStateName(NSString *name) {
    return [name isEqualToString:@"IDLE"] || [name isEqualToString:@"DOWN"]
        || [name isEqualToString:@"OFF"];
}

@implementation PHUDClockState
- (instancetype)initWithActive:(double)active clock:(double)clock cores:(NSInteger)cores {
    self = [super init];
    if (self) {
        _activePercent = active;
        _clockPercent = clock;
        _coreCount = cores;
    }
    return self;
}
@end

/// Running totals for one cluster while a sample is being folded together.
@interface PHUDClockAccumulator : NSObject
@property (nonatomic) double idleResidency;
@property (nonatomic) double activeResidency;
@property (nonatomic) double weightedRungs;   // Σ residency × normalised rung
@property (nonatomic) NSInteger cores;
@end
@implementation PHUDClockAccumulator
@end

@implementation PHUDClockReader {
    CFMutableDictionaryRef _channels[2];
    PHUDIOReportSubscriptionRef _subscriptions[2];
    CFDictionaryRef _previous[2];
    NSInteger _count;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    if (!PHUDIOReportStateAvailable()) return self;

    // CPU clusters and the GPU live in separate groups but decode identically.
    NSArray<NSArray<NSString *> *> *groups = @[
        @[@"CPU Stats", @"CPU Core Performance States"],
        @[@"GPU Stats", @"GPU Performance States"],
    ];

    for (NSArray<NSString *> *spec in groups) {
        CFMutableDictionaryRef channels = PHUD_IOReportCopyChannelsInGroup(
            (__bridge CFStringRef)spec[0], (__bridge CFStringRef)spec[1], 0, 0, 0);
        if (channels == NULL) continue;

        CFMutableDictionaryRef subscribed = NULL;
        PHUDIOReportSubscriptionRef sub = PHUD_IOReportCreateSubscription(NULL, channels, &subscribed, 0, NULL);
        CFRelease(channels);
        if (sub == NULL) {
            if (subscribed != NULL) CFRelease(subscribed);
            continue;
        }
        _channels[_count] = subscribed;
        _subscriptions[_count] = sub;
        _count++;
    }
    return self;
}

- (void)dealloc {
    for (NSInteger i = 0; i < _count; i++) {
        if (_previous[i] != NULL) CFRelease(_previous[i]);
        if (_channels[i] != NULL) CFRelease(_channels[i]);
        if (_subscriptions[i] != NULL) CFRelease(_subscriptions[i]);
    }
}

- (NSDictionary<NSString *, PHUDClockState *> *)sample {
    NSMutableDictionary<NSString *, PHUDClockAccumulator *> *totals = [NSMutableDictionary dictionary];

    for (NSInteger i = 0; i < _count; i++) {
        CFDictionaryRef current = PHUD_IOReportCreateSamples(_subscriptions[i], _channels[i], NULL);
        if (current == NULL) continue;

        CFDictionaryRef previous = _previous[i];
        _previous[i] = current;
        if (previous == NULL) continue;   // Priming call.

        CFDictionaryRef delta = PHUD_IOReportCreateSamplesDelta(previous, current, NULL);
        CFRelease(previous);
        if (delta == NULL) continue;

        PHUD_IOReportIterate(delta, ^int(CFDictionaryRef channel) {
            NSString *name = (__bridge NSString *)PHUD_IOReportChannelGetChannelName(channel);
            if (name == nil) return 0;

            int32_t stateCount = PHUD_IOReportStateGetCount(channel);
            if (stateCount <= 1) return 0;

            // Per-core CPU channels are "<family><cluster><core>" (PCPU0,
            // MCPU03); the GPU reports one channel. Fold cores up to the family,
            // not the physical cluster: a perf level can span several clusters
            // (this Mac's 12 "Performance" cores are MCPU0 + MCPU1), and the
            // family is the unit `hw.perflevelN` describes.
            NSString *cluster = @"GPU";
            if ([name hasPrefix:@"PCPU"] || [name hasPrefix:@"MCPU"]) {
                cluster = [name substringToIndex:4];
            }

            PHUDClockAccumulator *acc = totals[cluster];
            if (acc == nil) {
                acc = [PHUDClockAccumulator new];
                totals[cluster] = acc;
            }
            acc.cores += 1;

            // First pass: how many rungs are there, so a rung can be normalised.
            int32_t rungCount = 0;
            for (int32_t s = 0; s < stateCount; s++) {
                NSString *stateName = (__bridge NSString *)PHUD_IOReportStateGetNameForIndex(channel, s);
                if (stateName != nil && !PHUDIsIdleStateName(stateName)) rungCount++;
            }
            if (rungCount <= 1) return 0;

            int32_t rung = 0;
            for (int32_t s = 0; s < stateCount; s++) {
                NSString *stateName = (__bridge NSString *)PHUD_IOReportStateGetNameForIndex(channel, s);
                double residency = (double)PHUD_IOReportStateGetResidency(channel, s);
                if (residency < 0) continue;

                if (stateName == nil || PHUDIsIdleStateName(stateName)) {
                    acc.idleResidency += residency;
                } else {
                    // Channel order runs slowest → fastest, so position is the rung.
                    acc.activeResidency += residency;
                    acc.weightedRungs += residency * ((double)rung / (rungCount - 1));
                    rung++;
                }
            }
            return 0;
        });
        CFRelease(delta);
    }

    NSMutableDictionary<NSString *, PHUDClockState *> *result = [NSMutableDictionary dictionary];
    [totals enumerateKeysAndObjectsUsingBlock:^(NSString *cluster, PHUDClockAccumulator *acc, BOOL *stop) {
        double total = acc.idleResidency + acc.activeResidency;
        if (total <= 0) return;
        // With nothing running there's no meaningful clock to report, so hold at 0.
        double clock = acc.activeResidency > 0 ? acc.weightedRungs / acc.activeResidency * 100 : 0;
        result[cluster] = [[PHUDClockState alloc] initWithActive:acc.activeResidency / total * 100
                                                           clock:clock
                                                           cores:acc.cores];
    }];
    return result;
}

@end

#pragma mark - SMC (power delivery)

NSDictionary<NSString *, NSNumber *> *PHUDReadPower(void) {
    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];

    io_connect_t conn = PHUDSharedSMCConnection();
    if (conn == 0) {
        return result;
    }

    // PDTR ("DC in total") and PSTR ("system total") are the wattage keys Apple
    // Silicon Macs expose; both are "flt". Machines without an internal battery
    // have no PDTR, so a missing key is normal and simply omitted.
    struct { const char *key; NSString *label; } probes[] = {
        { "PDTR", @"in" },
        { "PSTR", @"system" },
    };

    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        SMCKeyData_t val;
        if (PHUDSMCReadKey(conn, probes[i].key, &val) != KERN_SUCCESS) continue;
        // An absent key still returns success but with a junk type, which would
        // decode to a bogus 0 W — so require the float type these keys use.
        if (val.keyInfo.dataType != PHUDStrToKey("flt ") || val.keyInfo.dataSize != 4) continue;

        float watts = PHUDDecodeSMCValue(&val);
        if (isfinite(watts) && watts >= 0.0f && watts < 1000.0f) {
            result[probes[i].label] = @(watts);
        }
    }

    return result;
}
