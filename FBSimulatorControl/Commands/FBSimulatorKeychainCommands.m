/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBSimulatorKeychainCommands.h"

#import "FBSimulator.h"
#import "FBSimulatorError.h"
#import "FBSimulatorLaunchCtlCommands.h"

static NSString *const SecuritydServiceName = @"com.apple.securityd";

@interface FBSimulatorKeychainCommands ()

@property (nonatomic, weak, readonly) FBSimulator *simulator;

@end

@implementation FBSimulatorKeychainCommands

+ (instancetype)commandsWithTarget:(FBSimulator *)target
{
  return [[self alloc] initWithSimulator:target];
}

- (instancetype)initWithSimulator:(FBSimulator *)simulator
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _simulator = simulator;

  return self;
}

#pragma mark Public

- (FBFuture<NSNull *> *)clearKeychain
{
  FBFuture<NSNull *> *stopServiceFuture = [FBFuture futureWithResult:NSNull.null];
  if (self.simulator.state == FBSimulatorStateBooted) {
    stopServiceFuture = [[self.simulator stopServiceWithName:SecuritydServiceName] mapReplace:NSNull.null];
  }
  return [stopServiceFuture
    onQueue:self.simulator.workQueue fmap:^(id _) {
      NSError *error = nil;
      if (![self removeKeychainDirectory:&error]) {
        return [FBFuture futureWithError:error];
      }
      if (self.simulator.state == FBSimulatorStateBooted) {
        return [[self.simulator startServiceWithName:SecuritydServiceName] mapReplace:NSNull.null];
      }
      return [FBFuture futureWithResult:NSNull.null];
    }];
}

#pragma mark Private

- (BOOL)removeKeychainDirectory:(NSError **)error
{
  NSString *keychainDirectory = [[self.simulator.dataDirectory
    stringByAppendingPathComponent:@"Library"]
    stringByAppendingPathComponent:@"Keychains"];
  if (![NSFileManager.defaultManager fileExistsAtPath:keychainDirectory]) {
    [self.simulator.logger.info logFormat:@"The keychain directory does not exist at '%@'", keychainDirectory];
    return YES;
  }
  NSError *innerError = nil;
  if (![NSFileManager.defaultManager removeItemAtPath:keychainDirectory error:&innerError]) {
    return [[[FBSimulatorError
      describeFormat:@"Failed to delete keychain directory at path %@", keychainDirectory]
      causedBy:innerError]
      failBool:error];
  }
  return YES;
}

@end
