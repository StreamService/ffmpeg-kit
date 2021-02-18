/*
 * Copyright (c) 2018-2021 Taner Sener
 *
 * This file is part of FFmpegKit.
 *
 * FFmpegKit is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * FFmpegKit is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with FFmpegKit.  If not, see <http://www.gnu.org/licenses/>.
 */

#import <stdatomic.h>
#import <sys/types.h>
#import <sys/stat.h>
#import "libavutil/ffversion.h"
#import "fftools_ffmpeg.h"
#import "ArchDetect.h"
#import "AtomicLong.h"
#import "FFmpegKit.h"
#import "FFmpegKitConfig.h"
#import "FFmpegSession.h"
#import "FFprobeKit.h"
#import "FFprobeSession.h"
#import "Level.h"
#import "LogRedirectionStrategy.h"
#import "MediaInformationSession.h"
#import "SessionState.h"

/** Global library version */
NSString* const FFmpegKitVersion = @"4.4";

/**
 * Prefix of named pipes created by ffmpeg-kit.
 */
NSString* const FFmpegKitNamedPipePrefix = @"fk_pipe_";

/**
 * Generates ids for named ffmpeg kit pipes.
 */
static AtomicLong* pipeIndexGenerator;

/* Session history variables */
static int sessionHistorySize;
static volatile NSMutableDictionary* sessionHistoryMap;
static NSMutableArray* sessionHistoryList;
static NSRecursiveLock* sessionHistoryLock;

/** Session control variables */
const int SESSION_MAP_SIZE = 1000;
static atomic_short sessionMap[SESSION_MAP_SIZE];
static atomic_int sessionInTransitMessageCountMap[SESSION_MAP_SIZE];

static dispatch_queue_t asyncDispatchQueue;

/** Holds callback defined to redirect logs */
static LogCallback logCallback;

/** Holds callback defined to redirect statistics */
static StatisticsCallback statisticsCallback;

/** Holds callback defined to redirect asynchronous execution results */
static ExecuteCallback executeCallback;

static LogRedirectionStrategy globalLogRedirectionStrategy;

/** Redirection control variables */
static int redirectionEnabled;
static NSRecursiveLock *lock;
static dispatch_semaphore_t semaphore;
static NSMutableArray *callbackDataArray;

/** Fields that control the handling of SIGNALs */
volatile int handleSIGQUIT = 1;
volatile int handleSIGINT = 1;
volatile int handleSIGTERM = 1;
volatile int handleSIGXCPU = 1;
volatile int handleSIGPIPE = 1;

/** Holds the id of the current execution */
__thread volatile long _sessionId = 0;

/** Holds the default log level */
int configuredLogLevel = LevelAVLogInfo;

/** Forward declaration for function defined in fftools_ffmpeg.c */
int ffmpeg_execute(int argc, char **argv);

/** Forward declaration for function defined in fftools_ffprobe.c */
int ffprobe_execute(int argc, char **argv);

typedef NS_ENUM(NSUInteger, CallbackType) {
    LogType,
    StatisticsType
};

/**
 * Callback data class.
 */
@interface CallbackData : NSObject

@end

@implementation CallbackData {
    CallbackType _type;
    long _sessionId;                    // session id

    int _logLevel;                      // log level
    NSString* _logData;                 // log data

    int _statisticsFrameNumber;         // statistics frame number
    float _statisticsFps;               // statistics fps
    float _statisticsQuality;           // statistics quality
    int64_t _statisticsSize;            // statistics size
    int _statisticsTime;                // statistics time
    double _statisticsBitrate;          // statistics bitrate
    double _statisticsSpeed;            // statistics speed
}

 - (instancetype)init:(long)sessionId logLevel:(int)logLevel data:(NSString*)logData {
    self = [super init];
    if (self) {
        _type = LogType;
        _sessionId = sessionId;
        _logLevel = logLevel;
        _logData = logData;
    }

    return self;
}

 - (instancetype)init:(long)sessionId
                            videoFrameNumber:(int)videoFrameNumber
                            fps:(float)videoFps
                            quality:(float)videoQuality
                            size:(int64_t)size
                            time:(int)time
                            bitrate:(double)bitrate
                            speed:(double)speed {
    self = [super init];
    if (self) {
        _type = StatisticsType;
        _sessionId = sessionId;
        _statisticsFrameNumber = videoFrameNumber;
        _statisticsFps = videoFps;
        _statisticsQuality = videoQuality;
        _statisticsSize = size;
        _statisticsTime = time;
        _statisticsBitrate = bitrate;
        _statisticsSpeed = speed;
    }

    return self;
}

- (CallbackType)getType {
    return _type;
}

- (long)getSessionId {
    return _sessionId;
}

- (int)getLogLevel {
    return _logLevel;
}

- (NSString*)getLogData {
    return _logData;
}

- (int)getStatisticsFrameNumber {
    return _statisticsFrameNumber;
}

- (float)getStatisticsFps {
    return _statisticsFps;
}

- (float)getStatisticsQuality {
    return _statisticsQuality;
}

- (int64_t)getStatisticsSize {
    return _statisticsSize;
}

- (int)getStatisticsTime {
    return _statisticsTime;
}

- (double)getStatisticsBitrate {
    return _statisticsBitrate;
}

- (double)getStatisticsSpeed {
    return _statisticsSpeed;
}

@end

/**
 * Waits on the callback semaphore for the given time.
 *
 * @param milliSeconds wait time in milliseconds
 */
void callbackWait(int milliSeconds) {
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(milliSeconds * NSEC_PER_MSEC)));
}

/**
 * Notifies threads waiting on callback semaphore.
 */
void callbackNotify() {
    dispatch_semaphore_signal(semaphore);
}

/**
 * Adds log data to the end of callback data list.
 *
 * @param level log level
 * @param logData log data
 */
void logCallbackDataAdd(int level, NSString *logData) {
    CallbackData* callbackData = [[CallbackData alloc] init:_sessionId logLevel:level data:logData];
    
    [lock lock];
    [callbackDataArray addObject:callbackData];
    [lock unlock];

    callbackNotify();

    atomic_fetch_add(&sessionInTransitMessageCountMap[_sessionId % SESSION_MAP_SIZE], 1);
}

/**
 * Adds statistics data to the end of callback data list.
 */
void statisticsCallbackDataAdd(int frameNumber, float fps, float quality, int64_t size, int time, double bitrate, double speed) {
    CallbackData *callbackData = [[CallbackData alloc] init:_sessionId videoFrameNumber:frameNumber fps:fps quality:quality size:size time:time bitrate:bitrate speed:speed];

    [lock lock];
    [callbackDataArray addObject:callbackData];
    [lock unlock];

    callbackNotify();
    
    atomic_fetch_add(&sessionInTransitMessageCountMap[_sessionId % SESSION_MAP_SIZE], 1);
}

/**
 * Removes head of callback data list.
 */
CallbackData *callbackDataRemove() {
    CallbackData *newData = nil;

    [lock lock];

    @try {
        if ([callbackDataArray count] > 0) {
            newData = [callbackDataArray objectAtIndex:0];
            [callbackDataArray removeObjectAtIndex:0];
        }
    } @catch(NSException *exception) {
        // DO NOTHING
    } @finally {
        [lock unlock];
    }

    return newData;
}

/**
 * Adds a session id to the session map.
 *
 * @param sessionId session id
 */
void addSession(long sessionId) {
    atomic_store(&sessionMap[sessionId % SESSION_MAP_SIZE], 1);
}

/**
 * Removes a session id from the session map.
 *
 * @param sessionId session id
 */
void removeSession(long sessionId) {
    atomic_store(&sessionMap[sessionId % SESSION_MAP_SIZE], 0);
}

/**
 * Adds a cancel session request to the session map.
 *
 * @param sessionId session id
 */
void cancelSession(long sessionId) {
    atomic_store(&sessionMap[sessionId % SESSION_MAP_SIZE], 2);
}

/**
 * Checks whether a cancel request for the given session id exists in the session map.
 *
 * @param sessionId session id
 * @return 1 if exists, false otherwise
 */
int cancelRequested(long sessionId) {
    if (atomic_load(&sessionMap[sessionId % SESSION_MAP_SIZE]) == 2) {
        return 1;
    } else {
        return 0;
    }
}

/**
 * Resets the number of messages in transmit for this session.
 *
 * @param sessionId session id
 */
void resetMessagesInTransmit(long sessionId) {
    atomic_store(&sessionInTransitMessageCountMap[sessionId % SESSION_MAP_SIZE], 0);
}

/**
 * Callback function for FFmpeg/FFprobe logs.
 *
 * @param ptr pointer to AVClass struct
 * @param level log level
 * @param format format string
 * @param vargs arguments
 */
void ffmpegkit_log_callback_function(void *ptr, int level, const char* format, va_list vargs) {

    // DO NOT PROCESS UNWANTED LOGS
    if (level >= 0) {
        level &= 0xff;
    }
    int activeLogLevel = av_log_get_level();

    // LevelAVLogStdErr logs are always redirected
    if ((activeLogLevel == LevelAVLogQuiet && level != LevelAVLogStdErr) || (level > activeLogLevel)) {
        return;
    }

    NSString *logData = [[NSString alloc] initWithFormat:[NSString stringWithCString:format encoding:NSUTF8StringEncoding] arguments:vargs];

    if (logData.length > 0) {
        logCallbackDataAdd(level, logData);
    }
}

/**
 * Callback function for FFmpeg statistics.
 *
 * @param frameNumber last processed frame number
 * @param fps frames processed per second
 * @param quality quality of the output stream (video only)
 * @param size size in bytes
 * @param time processed output duration
 * @param bitrate output bit rate in kbits/s
 * @param speed processing speed = processed duration / operation duration
 */
void ffmpegkit_statistics_callback_function(int frameNumber, float fps, float quality, int64_t size, int time, double bitrate, double speed) {
    statisticsCallbackDataAdd(frameNumber, fps, quality, size, time, bitrate, speed);
}

void process_log(long sessionId, int levelValue, NSString* logMessage) {
    int activeLogLevel = av_log_get_level();
    Log* log = [[Log alloc] init:sessionId:levelValue:logMessage];
    BOOL globalCallbackDefined = false;
    BOOL sessionCallbackDefined = false;
    LogRedirectionStrategy activeLogRedirectionStrategy = globalLogRedirectionStrategy;

    // LevelAVLogStdErr logs are always redirected
    if ((activeLogLevel == LevelAVLogQuiet && levelValue != LevelAVLogStdErr) || (levelValue > activeLogLevel)) {
        // LOG NEITHER PRINTED NOR FORWARDED
        return;
    }

    id<Session> session = [FFmpegKitConfig getSession:sessionId];
    if (session != nil) {
        activeLogRedirectionStrategy = [session getLogRedirectionStrategy];
        [session addLog:log];

        LogCallback sessionLogCallback = [session getLogCallback];
        if (sessionLogCallback != nil) {
            sessionCallbackDefined = TRUE;

            @try {
                // NOTIFY SESSION CALLBACK DEFINED
                sessionLogCallback(log);
            }
            @catch(NSException* exception) {
                NSLog(@"Exception thrown inside session LogCallback block. %@", [exception callStackSymbols]);
            }
        }
    }
    
    LogCallback globalLogCallback = logCallback;
    if (globalLogCallback != nil) {
        globalCallbackDefined = TRUE;

        @try {
            // NOTIFY GLOBAL CALLBACK DEFINED
            globalLogCallback(log);
        }
        @catch(NSException* exception) {
            NSLog(@"Exception thrown inside global LogCallback block. %@", [exception callStackSymbols]);
        }
    }
    
    // EXECUTE THE LOG STRATEGY
    switch (activeLogRedirectionStrategy) {
        case LogRedirectionStrategyNeverPrintLogs: {
            return;
        }
        case LogRedirectionStrategyPrintLogsWhenGlobalCallbackNotDefined: {
            if (globalCallbackDefined) {
                return;
            }
        }
        break;
        case LogRedirectionStrategyPrintLogsWhenSessionCallbackNotDefined: {
            if (sessionCallbackDefined) {
                return;
            }
        }
        case LogRedirectionStrategyPrintLogsWhenNoCallbacksDefined: {
            if (globalCallbackDefined || sessionCallbackDefined) {
                return;
            }
        }
        case LogRedirectionStrategyAlwaysPrintLogs: {
        }
    }

    // PRINT LOGS
    switch (levelValue) {
        case LevelAVLogQuiet:
            // PRINT NO OUTPUT
            break;
        default:
            // WRITE TO NSLOG
            NSLog(@"%@: %@", [FFmpegKitConfig logLevelToString:levelValue], logMessage);
            break;
    }
}

void process_statistics(long sessionId, int videoFrameNumber, float videoFps, float videoQuality, long size, int time, double bitrate, double speed) {
    
    Statistics *statistics = [[Statistics alloc] init:sessionId videoFrameNumber:videoFrameNumber videoFps:videoFps videoQuality:videoQuality size:size time:time bitrate:bitrate speed:speed];

    id<Session> session = [FFmpegKitConfig getSession:sessionId];
    if (session != nil && [session isFFmpeg]) {
        FFmpegSession *ffmpegSession = (FFmpegSession*)session;
        [ffmpegSession addStatistics:statistics];

        StatisticsCallback sessionStatisticsCallback = [ffmpegSession getStatisticsCallback];
        if (sessionStatisticsCallback != nil) {
            @try {
                sessionStatisticsCallback(statistics);
            }
            @catch(NSException* exception) {
                NSLog(@"Exception thrown inside session StatisticsCallback block. %@", [exception callStackSymbols]);
            }
        }
    }
    
    StatisticsCallback globalStatisticsCallback = statisticsCallback;
    if (globalStatisticsCallback != nil) {
        @try {
            globalStatisticsCallback(statistics);
        }
        @catch(NSException* exception) {
            NSLog(@"Exception thrown inside global StatisticsCallback block. %@", [exception callStackSymbols]);
        }
    }
}

/**
 * Forwards asynchronous messages to Callbacks.
 */
void callbackBlockFunction() {
    int activeLogLevel = av_log_get_level();
    if ((activeLogLevel != LevelAVLogQuiet) && (LevelAVLogDebug <= activeLogLevel)) {
        NSLog(@"Async callback block started.\n");
    }

    while(redirectionEnabled) {
        @autoreleasepool {
            @try {

                CallbackData *callbackData = callbackDataRemove();
                if (callbackData != nil) {

                    if ([callbackData getType] == LogType) {
                        process_log([callbackData getSessionId], [callbackData getLogLevel], [callbackData getLogData]);
                    } else {
                        process_statistics([callbackData getSessionId],
                                           [callbackData getStatisticsFrameNumber],
                                           [callbackData getStatisticsFps],
                                           [callbackData getStatisticsQuality],
                                           [callbackData getStatisticsSize],
                                           [callbackData getStatisticsTime],
                                           [callbackData getStatisticsBitrate],
                                           [callbackData getStatisticsSpeed]);
                    }
                    
                    atomic_fetch_sub(&sessionInTransitMessageCountMap[[callbackData getSessionId] % SESSION_MAP_SIZE], 1);

                } else {
                    callbackWait(100);
                }

            } @catch(NSException *exception) {
                activeLogLevel = av_log_get_level();
                if ((activeLogLevel != LevelAVLogQuiet) && (LevelAVLogWarning <= activeLogLevel)) {
                    NSLog(@"Async callback block received error: %@n\n", exception);
                    NSLog(@"%@", [exception callStackSymbols]);
                }
            }
        }
    }

    activeLogLevel = av_log_get_level();
    if ((activeLogLevel != LevelAVLogQuiet) && (LevelAVLogDebug <= activeLogLevel)) {
        NSLog(@"Async callback block stopped.\n");
    }
}

int executeFFmpeg(long sessionId, NSArray* arguments) {
    NSString* const LIB_NAME = @"ffmpeg";

    // SETS DEFAULT LOG LEVEL BEFORE STARTING A NEW RUN
    av_log_set_level(configuredLogLevel);

    char **commandCharPArray = (char **)av_malloc(sizeof(char*) * ([arguments count] + 1));

    /* PRESERVE USAGE FORMAT
     *
     * ffmpeg <arguments>
     */
    commandCharPArray[0] = (char *)av_malloc(sizeof(char) * ([LIB_NAME length] + 1));
    strcpy(commandCharPArray[0], [LIB_NAME UTF8String]);

    // PREPARE ARRAY ELEMENTS
    for (int i=0; i < [arguments count]; i++) {
        NSString *argument = [arguments objectAtIndex:i];
        commandCharPArray[i + 1] = (char *) [argument UTF8String];
    }

    // REGISTER THE ID BEFORE STARTING THE SESSION
    _sessionId = sessionId;
    addSession(sessionId);
    
    resetMessagesInTransmit(sessionId);

    // RUN
    int returnCode = ffmpeg_execute(([arguments count] + 1), commandCharPArray);

    // ALWAYS REMOVE THE ID FROM THE MAP
    removeSession(sessionId);

    // CLEANUP
    av_free(commandCharPArray[0]);
    av_free(commandCharPArray);

    return returnCode;
}

int executeFFprobe(long sessionId, NSArray* arguments) {
    NSString* const LIB_NAME = @"ffprobe";

    // SETS DEFAULT LOG LEVEL BEFORE STARTING A NEW RUN
    av_log_set_level(configuredLogLevel);

    char **commandCharPArray = (char **)av_malloc(sizeof(char*) * ([arguments count] + 1));

    /* PRESERVE USAGE FORMAT
     *
     * ffprobe <arguments>
     */
    commandCharPArray[0] = (char *)av_malloc(sizeof(char) * ([LIB_NAME length] + 1));
    strcpy(commandCharPArray[0], [LIB_NAME UTF8String]);

    // PREPARE ARRAY ELEMENTS
    for (int i=0; i < [arguments count]; i++) {
        NSString *argument = [arguments objectAtIndex:i];
        commandCharPArray[i + 1] = (char *) [argument UTF8String];
    }

    // REGISTER THE ID BEFORE STARTING THE SESSION
    _sessionId = sessionId;
    addSession(sessionId);

    resetMessagesInTransmit(sessionId);

    // RUN
    int returnCode = ffprobe_execute(([arguments count] + 1), commandCharPArray);

    // ALWAYS REMOVE THE ID FROM THE MAP
    removeSession(sessionId);
    
    // CLEANUP
    av_free(commandCharPArray[0]);
    av_free(commandCharPArray);

    return returnCode;
}

@implementation FFmpegKitConfig

+ (void)initialize {
    [ArchDetect class];
    [FFmpegKit class];
    [FFprobeKit class];

    pipeIndexGenerator = [[AtomicLong alloc] initWithValue:1];

    sessionHistorySize = 10;
    sessionHistoryMap = [[NSMutableDictionary alloc] init];
    sessionHistoryList = [[NSMutableArray alloc] init];
    sessionHistoryLock = [[NSRecursiveLock alloc] init];

    for(int i = 0; i<SESSION_MAP_SIZE; i++) {
        atomic_init(&sessionMap[i], 0);
        atomic_init(&sessionInTransitMessageCountMap[i], 0);
    }
    
    asyncDispatchQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    logCallback = nil;
    statisticsCallback = nil;
    executeCallback = nil;
    
    globalLogRedirectionStrategy = LogRedirectionStrategyPrintLogsWhenNoCallbacksDefined;
    
    redirectionEnabled = 0;
    lock = [[NSRecursiveLock alloc] init];
    semaphore = dispatch_semaphore_create(0);
    callbackDataArray = [[NSMutableArray alloc] init];
    
    [FFmpegKitConfig enableRedirection];
}

+ (void)enableRedirection {
    [lock lock];

    if (redirectionEnabled != 0) {
        [lock unlock];
        return;
    }
    redirectionEnabled = 1;

    [lock unlock];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        callbackBlockFunction();
    });

    av_log_set_callback(ffmpegkit_log_callback_function);
    set_report_callback(ffmpegkit_statistics_callback_function);
}

+ (void)disableRedirection {
    [lock lock];

    if (redirectionEnabled != 1) {
        [lock unlock];
        return;
    }
    redirectionEnabled = 0;

    [lock unlock];

    av_log_set_callback(av_log_default_callback);
    set_report_callback(nil);

    callbackNotify();
}

+ (int)setFontconfigConfigurationPath:(NSString*)path {
    return [FFmpegKitConfig setEnvironmentVariable:@"FONTCONFIG_PATH" value:path];
}

+ (void)setFontDirectory:(NSString*)fontDirectoryPath with:(NSDictionary*)fontNameMapping {
    [FFmpegKitConfig setFontDirectoryList:[NSArray arrayWithObject:fontDirectoryPath] with:fontNameMapping];
}

+ (void)setFontDirectoryList:(NSArray*)fontDirectoryArray with:(NSDictionary*)fontNameMapping {
    NSError *error = nil;
    BOOL isDirectory = YES;
    BOOL isFile = NO;
    int validFontNameMappingCount = 0;
    NSString *tempConfigurationDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fontconfig"];
    NSString *fontConfigurationFile = [tempConfigurationDirectory stringByAppendingPathComponent:@"fonts.conf"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:tempConfigurationDirectory isDirectory:&isDirectory]) {
        if (![[NSFileManager defaultManager] createDirectoryAtPath:tempConfigurationDirectory withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Failed to set font directory. Error received while creating temp conf directory: %@.", error);
            return;
        }
        NSLog(@"Created temporary font conf directory: TRUE.");
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:fontConfigurationFile isDirectory:&isFile]) {
        BOOL fontConfigurationDeleted = [[NSFileManager defaultManager] removeItemAtPath:fontConfigurationFile error:nil];
        NSLog(@"Deleted old temporary font configuration: %s.", fontConfigurationDeleted?"TRUE":"FALSE");
    }

    /* PROCESS MAPPINGS FIRST */
    NSString *fontNameMappingBlock = @"";
    for (NSString *fontName in [fontNameMapping allKeys]) {
        NSString *mappedFontName = [fontNameMapping objectForKey:fontName];

        if ((fontName != nil) && (mappedFontName != nil) && ([fontName length] > 0) && ([mappedFontName length] > 0)) {

            fontNameMappingBlock = [NSString stringWithFormat:@"%@\n%@\n%@%@%@\n%@\n%@\n%@%@%@\n%@\n%@\n",
                @"        <match target=\"pattern\">",
                @"                <test qual=\"any\" name=\"family\">",
                @"                        <string>", fontName, @"</string>",
                @"                </test>",
                @"                <edit name=\"family\" mode=\"assign\" binding=\"same\">",
                @"                        <string>", mappedFontName, @"</string>",
                @"                </edit>",
                @"        </match>"];

            validFontNameMappingCount++;
        }
    }

    NSMutableString *fontConfiguration = [NSMutableString stringWithFormat:@"%@\n%@\n%@\n%@\n",
                            @"<?xml version=\"1.0\"?>",
                            @"<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">",
                            @"<fontconfig>",
                            @"    <dir prefix=\"cwd\">.</dir>"];
    for (int i=0; i < [fontDirectoryArray count]; i++) {
        NSString *fontDirectoryPath = [fontDirectoryArray objectAtIndex:i];
        [fontConfiguration appendString: @"    <dir>"];
        [fontConfiguration appendString: fontDirectoryPath];
        [fontConfiguration appendString: @"</dir>"];
    }
    [fontConfiguration appendString:fontNameMappingBlock];
    [fontConfiguration appendString:@"</fontconfig>"];

    if (![fontConfiguration writeToFile:fontConfigurationFile atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSLog(@"Failed to set font directory. Error received while saving font configuration: %@.", error);
        return;
    }

    NSLog(@"Saved new temporary font configuration with %d font name mappings.", validFontNameMappingCount);

    [FFmpegKitConfig setFontconfigConfigurationPath:tempConfigurationDirectory];

    for (int i=0; i < [fontDirectoryArray count]; i++) {
        NSString *fontDirectoryPath = [fontDirectoryArray objectAtIndex:i];
        NSLog(@"Font directory %@ registered successfully.", fontDirectoryPath);
    }
}

+ (NSString*)registerNewFFmpegPipe {
    NSError *error = nil;
    BOOL isDirectory;

    // PIPES ARE CREATED UNDER THE PIPES DIRECTORY
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *pipesDir = [cacheDir stringByAppendingPathComponent:@"pipes"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:pipesDir isDirectory:&isDirectory]) {
        if (![[NSFileManager defaultManager] createDirectoryAtPath:pipesDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Failed to create pipes directory: %@. Operation failed with %@.", pipesDir, error);
            return nil;
        }
    }

    NSString *newFFmpegPipePath = [NSString stringWithFormat:@"%@/%@%ld", pipesDir, FFmpegKitNamedPipePrefix, [pipeIndexGenerator getAndIncrement]];

    // FIRST CLOSE OLD PIPES WITH THE SAME NAME
    [FFmpegKitConfig closeFFmpegPipe:newFFmpegPipePath];

    int rc = mkfifo([newFFmpegPipePath UTF8String], S_IRWXU | S_IRWXG | S_IROTH);
    if (rc == 0) {
        return newFFmpegPipePath;
    } else {
        NSLog(@"Failed to register new FFmpeg pipe %@. Operation failed with rc=%d.", newFFmpegPipePath, rc);
        return nil;
    }
}

+ (void)closeFFmpegPipe:(NSString*)ffmpegPipePath {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if ([fileManager fileExistsAtPath:ffmpegPipePath]){
        [fileManager removeItemAtPath:ffmpegPipePath error:nil];
    }
}

+ (NSString*)getFFmpegVersion {
    return [NSString stringWithUTF8String:FFMPEG_VERSION];
}

+ (NSString*)getVersion {
    if ([FFmpegKitConfig isLTSBuild] == 1) {
        return [NSString stringWithFormat:@"%@-lts", FFmpegKitVersion];
    } else {
        return FFmpegKitVersion;
    }
}

+ (int)isLTSBuild {
    #if defined(FFMPEG_KIT_LTS)
        return 1;
    #else
        return 0;
    #endif
}

+ (NSString*)getBuildDate {
    char buildDate[10];
    sprintf(buildDate, "%d", FFMPEG_KIT_BUILD_DATE);
    return [NSString stringWithUTF8String:buildDate];
}

+ (int)setEnvironmentVariable:(NSString*)variableName value:(NSString*)variableValue {
    return setenv([variableName UTF8String], [variableValue UTF8String], true);
}

+ (void)ignoreSignal:(Signal)signal {
    if (signal == SignalQuit) {
        handleSIGQUIT = 0;
    } else if (signal == SignalInt) {
        handleSIGINT = 0;
    } else if (signal == SignalTerm) {
        handleSIGTERM = 0;
    } else if (signal == SignalXcpu) {
        handleSIGXCPU = 0;
    } else if (signal == SignalPipe) {
        handleSIGPIPE = 0;
    }
}

+ (void)ffmpegExecute:(FFmpegSession*)ffmpegSession {
    [FFmpegKitConfig addSession:ffmpegSession];
    [ffmpegSession startRunning];
    
    @try {
        int returnCode = executeFFmpeg([ffmpegSession getSessionId], [ffmpegSession getArguments]);
        [ffmpegSession complete:[[ReturnCode alloc] init:returnCode]];
    } @catch (NSException *exception) {
        [ffmpegSession fail:exception];
        NSLog(@"FFmpeg execute failed: %@.%@", [FFmpegKit argumentsToString:[ffmpegSession getArguments]], [NSString stringWithFormat:@"%@", [exception callStackSymbols]]);
    }
}

+ (void)ffprobeExecute:(FFprobeSession*)ffprobeSession {
    [FFmpegKitConfig addSession:ffprobeSession];
    [ffprobeSession startRunning];
    
    @try {
        int returnCode = executeFFprobe([ffprobeSession getSessionId], [ffprobeSession getArguments]);
        [ffprobeSession complete:[[ReturnCode alloc] init:returnCode]];
    } @catch (NSException *exception) {
        [ffprobeSession fail:exception];
        NSLog(@"FFprobe execute failed: %@.%@", [FFmpegKit argumentsToString:[ffprobeSession getArguments]], [NSString stringWithFormat:@"%@", [exception callStackSymbols]]);
    }
}

+ (void)getMediaInformationExecute:(MediaInformationSession*)mediaInformationSession withTimeout:(int)waitTimeout {
    [FFmpegKitConfig addSession:mediaInformationSession];
    [mediaInformationSession startRunning];
    
    @try {
        int returnCodeValue = executeFFprobe([mediaInformationSession getSessionId], [mediaInformationSession getArguments]);
        ReturnCode* returnCode = [[ReturnCode alloc] init:returnCodeValue];
        [mediaInformationSession complete:returnCode];
        if ([returnCode isSuccess]) {
            MediaInformation* mediaInformation = [MediaInformationJsonParser from:[mediaInformationSession getAllLogsAsStringWithTimeout:waitTimeout]];
            [mediaInformationSession setMediaInformation:mediaInformation];
        }
    } @catch (NSException *exception) {
        [mediaInformationSession fail:exception];
        NSLog(@"Get media information execute failed: %@.%@", [FFmpegKit argumentsToString:[mediaInformationSession getArguments]], [NSString stringWithFormat:@"%@", [exception callStackSymbols]]);
    }
}

+ (void)asyncFFmpegExecute:(FFmpegSession*)ffmpegSession {
    [FFmpegKitConfig asyncFFmpegExecute:ffmpegSession onDispatchQueue:asyncDispatchQueue];
}

+ (void)asyncFFmpegExecute:(FFmpegSession*)ffmpegSession onDispatchQueue:(dispatch_queue_t)queue {
    dispatch_async(queue, ^{
        [FFmpegKitConfig ffmpegExecute:ffmpegSession];
        ExecuteCallback globalExecuteCallback = [FFmpegKitConfig getExecuteCallback];
        if (globalExecuteCallback != nil) {
            globalExecuteCallback(ffmpegSession);
        }
        
        ExecuteCallback sessionExecuteCallback = [ffmpegSession getExecuteCallback];
        if (sessionExecuteCallback != nil) {
            sessionExecuteCallback(ffmpegSession);
        }
    });
}

+ (void)asyncFFprobeExecute:(FFprobeSession*)ffprobeSession {
    [FFmpegKitConfig asyncFFprobeExecute:ffprobeSession onDispatchQueue:asyncDispatchQueue];
}

+ (void)asyncFFprobeExecute:(FFprobeSession*)ffprobeSession onDispatchQueue:(dispatch_queue_t)queue {
    dispatch_async(queue, ^{
        [FFmpegKitConfig ffprobeExecute:ffprobeSession];
        ExecuteCallback globalExecuteCallback = [FFmpegKitConfig getExecuteCallback];
        if (globalExecuteCallback != nil) {
            globalExecuteCallback(ffprobeSession);
        }
        
        ExecuteCallback sessionExecuteCallback = [ffprobeSession getExecuteCallback];
        if (sessionExecuteCallback != nil) {
            sessionExecuteCallback(ffprobeSession);
        }
    });
}

+ (void)asyncGetMediaInformationExecute:(MediaInformationSession*)mediaInformationSession withTimeout:(int)waitTimeout {
    [FFmpegKitConfig asyncGetMediaInformationExecute:mediaInformationSession onDispatchQueue:asyncDispatchQueue withTimeout:waitTimeout];
}

+ (void)asyncGetMediaInformationExecute:(MediaInformationSession*)mediaInformationSession onDispatchQueue:(dispatch_queue_t)queue withTimeout:(int)waitTimeout {
    dispatch_async(queue, ^{
        [FFmpegKitConfig getMediaInformationExecute:mediaInformationSession withTimeout:waitTimeout];
        ExecuteCallback globalExecuteCallback = [FFmpegKitConfig getExecuteCallback];
        if (globalExecuteCallback != nil) {
            globalExecuteCallback(mediaInformationSession);
        }
        
        ExecuteCallback sessionExecuteCallback = [mediaInformationSession getExecuteCallback];
        if (sessionExecuteCallback != nil) {
            sessionExecuteCallback(mediaInformationSession);
        }
    });
}

+ (void)enableLogCallback:(LogCallback)callback {
    logCallback = callback;
}

+ (void)enableStatisticsCallback:(StatisticsCallback)callback {
    statisticsCallback = callback;
}

+ (void)enableExecuteCallback:(ExecuteCallback)callback {
    executeCallback = callback;
}

+ (ExecuteCallback)getExecuteCallback {
    return executeCallback;
}

+ (int)getLogLevel {
    return configuredLogLevel;
}

+ (void)setLogLevel:(int)level {
    configuredLogLevel = level;
}

+ (NSString*)logLevelToString:(int)level {
    switch (level) {
        case LevelAVLogStdErr: return @"STDERR";
        case LevelAVLogTrace: return @"TRACE";
        case LevelAVLogDebug: return @"DEBUG";
        case LevelAVLogVerbose: return @"VERBOSE";
        case LevelAVLogInfo: return @"INFO";
        case LevelAVLogWarning: return @"WARNING";
        case LevelAVLogError: return @"ERROR";
        case LevelAVLogFatal: return @"FATAL";
        case LevelAVLogPanic: return @"PANIC";
        case LevelAVLogQuiet: return @"QUIET";
        default: return @"";
    }
}

+ (int)getSessionHistorySize {
    return sessionHistorySize;
}

+ (void)setSessionHistorySize:(int)pSessionHistorySize {
    if (pSessionHistorySize >= SESSION_MAP_SIZE) {

        /*
         * THERE IS A HARD LIMIT ON THE NATIVE SIDE. HISTORY SIZE MUST BE SMALLER THAN SESSION_MAP_SIZE
         */
        @throw([NSException exceptionWithName:NSInvalidArgumentException reason:@"Session history size must not exceed the hard limit!" userInfo:nil]);
    } else if (pSessionHistorySize > 0) {
        sessionHistorySize = pSessionHistorySize;
    }
}

+ (void)addSession:(id<Session>)session {
    [sessionHistoryLock lock];

    [sessionHistoryMap setObject:session forKey:[NSNumber numberWithLong:[session getSessionId]]];
    [sessionHistoryList addObject:session];
    if ([sessionHistoryList count] > sessionHistorySize) {
        id<Session> first = [sessionHistoryList firstObject];
        if (first != nil) {
            NSNumber* key = [NSNumber numberWithLong:[first getSessionId]];
            [sessionHistoryList removeObject:key];
            [sessionHistoryMap removeObjectForKey:key];
        }
    }
    
    [sessionHistoryLock unlock];
}

+ (id<Session>)getSession:(long)sessionId {
    [sessionHistoryLock lock];
    
    id<Session> session = [sessionHistoryMap objectForKey:[NSNumber numberWithLong:sessionId]];
    
    [sessionHistoryLock unlock];
    
    return session;
}

+ (id<Session>)getLastSession {
    [sessionHistoryLock lock];

    id<Session> lastSession = [sessionHistoryList lastObject];

    [sessionHistoryLock unlock];

    return lastSession;
}

+ (id<Session>)getLastCompletedSession {
    id<Session> lastCompletedSession = nil;

    [sessionHistoryLock lock];

    for(int i = [sessionHistoryList count] - 1; i >= 0; i--) {
        id<Session> session = [sessionHistoryList objectAtIndex:i];
        if ([session getState] == SessionStateCompleted) {
            lastCompletedSession = session;
            break;
        }
    }

    [sessionHistoryLock unlock];

    return lastCompletedSession;
}

+ (NSArray*)getSessions {
    [sessionHistoryLock lock];

    NSArray* sessionsCopy = [sessionHistoryList copy];

    [sessionHistoryLock unlock];
    
    return sessionsCopy;
}

+ (NSArray*)getFFmpegSessions {
    NSMutableArray* ffmpegSessions = [[NSMutableArray alloc] init];

    [sessionHistoryLock lock];

    for(int i = 0; i < [sessionHistoryList count]; i++) {
        id<Session> session = [sessionHistoryList objectAtIndex:i];
        if ([session isFFmpeg]) {
            [ffmpegSessions addObject:session];
        }
    }

    [sessionHistoryLock unlock];

    return ffmpegSessions;
}

+ (NSArray*)getFFprobeSessions {
    NSMutableArray* ffprobeSessions = [[NSMutableArray alloc] init];

    [sessionHistoryLock lock];

    for(int i = 0; i < [sessionHistoryList count]; i++) {
        id<Session> session = [sessionHistoryList objectAtIndex:i];
        if ([session isFFprobe]) {
            [ffprobeSessions addObject:session];
        }
    }

    [sessionHistoryLock unlock];

    return ffprobeSessions;
}

+ (NSArray*)getSessionsByState:(SessionState)state {
    NSMutableArray* sessions = [[NSMutableArray alloc] init];

    [sessionHistoryLock lock];

    for(int i = 0; i < [sessionHistoryList count]; i++) {
        id<Session> session = [sessionHistoryList objectAtIndex:i];
        if ([session getState] == state) {
            [sessions addObject:session];
        }
    }

    [sessionHistoryLock unlock];

    return sessions;
}

+ (LogRedirectionStrategy)getLogRedirectionStrategy {
   return globalLogRedirectionStrategy;
}

+ (void)setLogRedirectionStrategy:(LogRedirectionStrategy)logRedirectionStrategy {
    globalLogRedirectionStrategy = logRedirectionStrategy;
}

+ (int)messagesInTransmit:(long)sessionId {
    return atomic_load(&sessionInTransitMessageCountMap[sessionId % SESSION_MAP_SIZE]);
}

@end
