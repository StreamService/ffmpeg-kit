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

#ifndef FFMPEG_KIT_LOG_DELEGATE_H
#define FFMPEG_KIT_LOG_DELEGATE_H

#import <Foundation/Foundation.h>
#import "Log.h"

/**
 * <p>Delegate that receives logs generated for <code>FFmpegKit</code> sessions.
 */
@protocol LogDelegate<NSObject>
@required

/**
 * <p>Called when a log entry is received.
 *
 * @param log log entry
 */
- (void)logCallback:(Log*)log;

@end

#endif // FFMPEG_KIT_LOG_DELEGATE_H
