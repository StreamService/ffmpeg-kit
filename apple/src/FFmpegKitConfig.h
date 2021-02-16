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

#ifndef FFMPEG_KIT_CONFIG_H
#define FFMPEG_KIT_CONFIG_H

#import <stdio.h>
#import <pthread.h>
#import <unistd.h>
#import <Foundation/Foundation.h>
#import "ExecuteCallback.h"
#import "FFmpegSession.h"
#import "FFprobeSession.h"
#import "LogCallback.h"
#import "MediaInformationSession.h"
#import "StatisticsCallback.h"

/** Global library version */
extern NSString* const FFmpegKitVersion;

typedef NS_ENUM(NSUInteger, Signal) {
    SignalInt = 2,
    SignalQuit = 3,
    SignalPipe = 13,
    SignalTerm = 15,
    SignalXcpu = 24
};

/**
 * <p>Configuration class of <code>FFmpegKit</code> library. Allows customizing the global library
 * options. Provides helper methods to support additional resources.
 */
@interface FFmpegKitConfig : NSObject

/**
 * <p>Enables log and statistics redirection.
 *
 * <p>When redirection is enabled FFmpeg/FFprobe logs are redirected to NSLog and sessions
 * collect log and statistics entries for the executions. It is possible to define global or
 * session specific log/statistics callbacks as well.
 *
 * <p>Note that redirection is enabled by default. If you do not want to use its functionality
 * please use disableRedirection method to disable it.
 */
+ (void)enableRedirection;

/**
 * <p>Disables log and statistics redirection.
 *
 * <p>When redirection is disabled logs are printed to stderr, all logs and statistics
 * callbacks are disabled and <code>FFprobe</code>'s <code>getMediaInformation</code> methods
 * do not work.
 */
+ (void)disableRedirection;

/**
 * <p>Sets and overrides <code>fontconfig</code> configuration directory.
 *
 * @param path directory that contains fontconfig configuration (fonts.conf)
 * @return zero on success, non-zero on error
 */
+ (int)setFontconfigConfigurationPath:(NSString*)path;

/**
 * <p>Registers the fonts inside the given path, so they become available to use in FFmpeg
 * filters.
 *
 * <p>Note that you need to build <code>FFmpegKit</code> with <code>fontconfig</code>
 * enabled or use a prebuilt package with <code>fontconfig</code> inside to be able to use
 * fonts in <code>FFmpeg</code>.
 *
 * @param fontDirectoryPath directory that contains fonts (.ttf and .otf files)
 * @param fontNameMapping   custom font name mappings, useful to access your fonts with more
 *                          friendly names
 */
+ (void)setFontDirectory:(NSString*)fontDirectoryPath with:(NSDictionary*)fontNameMapping;

/**
 * <p>Registers the fonts inside the given array of font directories, so they become available
 * to use in FFmpeg filters.
 *
 * <p>Note that you need to build <code>FFmpegKit</code> with <code>fontconfig</code>
 * enabled or use a prebuilt package with <code>fontconfig</code> inside to be able to use
 * fonts in <code>FFmpeg</code>.
 *
 * @param fontDirectoryList array of directories that contain fonts (.ttf and .otf files)
 * @param fontNameMapping   custom font name mappings, useful to access your fonts with more
 *                          friendly names
 */
+ (void)setFontDirectoryList:(NSArray*)fontDirectoryList with:(NSDictionary*)fontNameMapping;

/**
 * <p>Creates a new named pipe to use in <code>FFmpeg</code> operations.
 *
 * <p>Please note that creator is responsible of closing created pipes.
 *
 * @return the full path of the named pipe
 */
+ (NSString*)registerNewFFmpegPipe;

/**
 * <p>Closes a previously created <code>FFmpeg</code> pipe.
 *
 * @param ffmpegPipePath full path of the FFmpeg pipe
 */
+ (void)closeFFmpegPipe:(NSString*)ffmpegPipePath;

/**
 * <p>Returns the version of FFmpeg bundled within <code>FFmpegKit</code> library.
 *
 * @return the version of FFmpeg
 */
+ (NSString*)getFFmpegVersion;

/**
 * Returns FFmpegKit library version.
 *
 * @return FFmpegKit version
 */
+ (NSString*)getVersion;

/**
 * <p>Returns whether FFmpegKit release is a Long Term Release or not.
 *
 * @return true/yes or false/no
 */
+ (int)isLTSBuild;

/**
 * Returns FFmpegKit library build date.
 *
 * @return FFmpegKit library build date
 */
+ (NSString*)getBuildDate;

/**
 * <p>Sets an environment variable.
 *
 * @param variableName  environment variable name
 * @param variableValue environment variable value
 * @return zero on success, non-zero on error
 */
+ (int)setEnvironmentVariable:(NSString*)variableName value:(NSString*)variableValue;

/**
 * <p>Registers a new ignored signal. Ignored signals are not handled by <code>FFmpegKit</code>
 * library.
 *
 * @param signal signal to be ignored
 */
+ (void)ignoreSignal:(Signal)signal;

/**
 * <p>Synchronously executes the FFmpeg session provided.
 *
 * @param ffmpegSession FFmpeg session which includes command options/arguments
 */
+ (void)ffmpegExecute:(FFmpegSession*)ffmpegSession;

/**
 * <p>Synchronously executes the FFprobe session provided.
 *
 * @param ffprobeSession FFprobe session which includes command options/arguments
 */
+ (void)ffprobeExecute:(FFprobeSession*)ffprobeSession;

/**
 * <p>Synchronously executes the media information session provided.
 *
 * @param mediaInformationSession media information session which includes command options/arguments
 * @param waitTimeout             max time to wait until media information is transmitted
 */
+ (void)getMediaInformationExecute:(MediaInformationSession*)mediaInformationSession withTimeout:(int)waitTimeout;

/**
 * <p>Asynchronously executes the FFmpeg session provided.
 *
 * @param ffmpegSession FFmpeg session which includes command options/arguments
 */
+ (void)asyncFFmpegExecute:(FFmpegSession*)ffmpegSession;

/**
 * <p>Asynchronously executes the FFmpeg session provided.
 *
 * @param ffmpegSession   FFmpeg session which includes command options/arguments
 * @param queue           dispatch queue that will be used to run this asynchronous operation
 */
+ (void)asyncFFmpegExecute:(FFmpegSession*)ffmpegSession onDispatchQueue:(dispatch_queue_t)queue;

/**
 * <p>Asynchronously executes the FFprobe session provided.
 *
 * @param ffprobeSession FFprobe session which includes command options/arguments
 */
+ (void)asyncFFprobeExecute:(FFprobeSession*)ffprobeSession;

/**
 * <p>Asynchronously executes the FFprobe session provided.
 *
 * @param ffprobeSession  FFprobe session which includes command options/arguments
 * @param queue           dispatch queue that will be used to run this asynchronous operation
 */
+ (void)asyncFFprobeExecute:(FFprobeSession*)ffprobeSession onDispatchQueue:(dispatch_queue_t)queue;

/**
 * <p>Asynchronously executes the media information session provided.
 *
 * @param mediaInformationSession media information session which includes command options/arguments
 * @param waitTimeout             max time to wait until media information is transmitted
 */
+ (void)asyncGetMediaInformationExecute:(MediaInformationSession*)mediaInformationSession withTimeout:(int)waitTimeout;

/**
 * <p>Asynchronously executes the media information session provided.
 *
 * @param mediaInformationSession media information session which includes command options/arguments
 * @param queue           dispatch queue that will be used to run this asynchronous operation
 * @param waitTimeout             max time to wait until media information is transmitted
 */
+ (void)asyncGetMediaInformationExecute:(MediaInformationSession*)mediaInformationSession onDispatchQueue:(dispatch_queue_t)queue withTimeout:(int)waitTimeout;

/**
 * <p>Sets a global log callback to redirect FFmpeg/FFprobe logs.
 *
 * @param logCallback log callback or nil to disable a previously defined log callback
 */
+ (void)enableLogCallback:(LogCallback)logCallback;

/**
 * <p>Sets a global statistics callback to redirect FFmpeg statistics.
 *
 * @param statisticsCallback statistics callback or nil to disable a previously defined statistics callback
 */
+ (void)enableStatisticsCallback:(StatisticsCallback)statisticsCallback;

/**
 * <p>Sets a global execute callback to receive execution results.
 *
 * @param executeCallback execute callback or nil to disable a previously execute callback
 */
+ (void)enableExecuteCallback:(ExecuteCallback)executeCallback;

/**
 * <p>Returns the global execute callback.
 *
 * @return global execute callback
 */
+ (ExecuteCallback)getExecuteCallback;

/**
 * Returns the current log level.
 *
 * @return current log level
 */
+ (int)getLogLevel;

/**
 * Sets the log level.
 *
 * @param level new log level
 */
+ (void)setLogLevel:(int)level;

/**
 * Converts int log level to string.
 *
 * @param level value
 * @return string value
 */
+ (NSString*)logLevelToString:(int)level;

/**
 * Returns the session history size.
 *
 * @return session history size
 */
+ (int)getSessionHistorySize;

/**
 * Sets the session history size.
 *
 * @param sessionHistorySize session history size, should be smaller than 1000
 */
+ (void)setSessionHistorySize:(int)sessionHistorySize;

/**
 * Returns the session specified with <code>sessionId</code> from the session history.
 *
 * @param sessionId session identifier
 * @return session specified with sessionId or nil if it is not found in the history
 */
+ (id<Session>)getSession:(long)sessionId;

/**
 * Returns the last session created from the session history.
 *
 * @return the last session created or nil if session history is empty
 */
+ (id<Session>)getLastSession;

/**
 * Returns the last session completed from the session history.
 *
 * @return the last session completed. If there are no completed sessions in the history this
 * method will return nil
 */
+ (id<Session>)getLastCompletedSession;

/**
 * <p>Returns all sessions in the session history.
 *
 * @return all sessions in the session history
 */
+ (NSArray*)getSessions;

/**
 * <p>Returns all FFmpeg sessions in the session history.
 *
 * @return all FFmpeg sessions in the session history
 */
+ (NSArray*)getFFmpegSessions;

/**
 * <p>Returns all FFprobe sessions in the session history.
 *
 * @return all FFprobe sessions in the session history
 */
+ (NSArray*)getFFprobeSessions;

/**
 * <p>Returns sessions that have the given state.
 *
 * @return sessions that have the given state from the session history
 */
+ (NSArray*)getSessionsByState:(SessionState)state;

/**
 * Returns the active log redirection strategy.
 *
 * @return log redirection strategy
 */
+ (LogRedirectionStrategy)getLogRedirectionStrategy;

/**
 * <p>Sets the log redirection strategy
 *
 * @param logRedirectionStrategy log redirection strategy
 */
+ (void)setLogRedirectionStrategy:(LogRedirectionStrategy)logRedirectionStrategy;

/**
 * <p>Returns the number of async messages that are not transmitted to the callbacks for
 * this session.
 *
 * @param sessionId id of the session
 * @return number of async messages that are not transmitted to the callbacks for this session
 */
+ (int)messagesInTransmit:(long)sessionId;

@end

#endif // FFMPEG_KIT_CONFIG_H
