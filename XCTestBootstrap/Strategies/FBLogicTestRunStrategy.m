/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBLogicTestRunStrategy.h"
#import "FBLogicXCTestReporter.h"

#import <sys/types.h>
#import <sys/stat.h>

#import <FBControlCore/FBControlCore.h>
#import <XCTestBootstrap/XCTestBootstrap.h>

@interface FBLogicTestRunStrategy ()

@property (nonatomic, strong, readonly) id<FBXCTestProcessExecutor> executor;
@property (nonatomic, strong, readonly) FBLogicTestConfiguration *configuration;
@property (nonatomic, strong, readonly) id<FBLogicXCTestReporter> reporter;
@property (nonatomic, strong, readonly) id<FBControlCoreLogger> logger;

@end

@implementation FBLogicTestRunStrategy

#pragma mark Initializers

+ (instancetype)strategyWithExecutor:(id<FBXCTestProcessExecutor>)executor configuration:(FBLogicTestConfiguration *)configuration reporter:(id<FBLogicXCTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger
{
  return [[FBLogicTestRunStrategy alloc] initWithExecutor:executor configuration:configuration reporter:reporter logger:logger];
}

- (instancetype)initWithExecutor:(id<FBXCTestProcessExecutor>)executor configuration:(FBLogicTestConfiguration *)configuration reporter:(id<FBLogicXCTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _executor = executor;
  _configuration = configuration;
  _reporter = reporter;
  _logger = logger;

  return self;
}

#pragma mark Public

- (FBFuture<NSNull *> *)execute
{
  NSTimeInterval timeout = self.configuration.testTimeout + 5;
  return [[self testFuture] timeout:timeout waitingFor:@"Logic Test Execution to finish"];
}

- (FBFuture<NSNull *> *)testFuture
{
  id<FBLogicXCTestReporter> reporter = self.reporter;
  BOOL mirrorToFiles = (self.configuration.mirroring & FBLogicTestMirrorFileLogs) != 0;
  BOOL mirrorToLogger = (self.configuration.mirroring & FBLogicTestMirrorLogger) != 0;
  id<FBControlCoreLogger> logger = self.logger;
  FBXCTestLogger *mirrorLogger = [FBXCTestLogger defaultLoggerInDefaultDirectory];

  [reporter didBeginExecutingTestPlan];

  NSString *xctestPath = self.executor.xctestPath;
  NSString *shimPath = self.executor.shimPath;

  // The fifo is used by the shim to report events from within the xctest framework.
  NSString *otestShimOutputPath = [self.configuration.workingDirectory stringByAppendingPathComponent:@"shim-output-pipe"];
  if (mkfifo(otestShimOutputPath.UTF8String, S_IWUSR | S_IRUSR) != 0) {
    NSError *posixError = [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    return [[[FBXCTestError
      describeFormat:@"Failed to create a named pipe %@", otestShimOutputPath]
      causedBy:posixError]
      failFuture];
  }

  // The environment requires the shim path and otest-shim path.
  NSMutableDictionary<NSString *, NSString *> *environment = [NSMutableDictionary dictionaryWithDictionary:@{
    @"DYLD_INSERT_LIBRARIES": shimPath,
    @"OTEST_SHIM_STDOUT_FILE": otestShimOutputPath,
    @"TEST_SHIM_BUNDLE_PATH": self.configuration.testBundlePath,
    @"FB_TEST_TIMEOUT": @(self.configuration.testTimeout).stringValue,
  }];
  [environment addEntriesFromDictionary:self.configuration.processUnderTestEnvironment];

  // Get the Launch Path and Arguments for the xctest process.
  NSString *testSpecifier = self.configuration.testFilter ?: @"All";
  NSString *launchPath = xctestPath;
  NSArray<NSString *> *arguments = @[@"-XCTest", testSpecifier, self.configuration.testBundlePath];

  // Consumes the test output. Separate Readers are used as consuming an EOF will invalidate the reader.
  NSUUID *uuid = [NSUUID UUID];

  // Setup the stdout reader.
  id<FBFileConsumer> stdOutConsumer = [FBLineFileConsumer asynchronousReaderWithQueue:self.executor.workQueue consumer:^(NSString *line){
    [reporter testHadOutput:[line stringByAppendingString:@"\n"]];
    if (mirrorToLogger) {
      [mirrorLogger logFormat:@"[Test Output] %@", line];
    }
  }];
  if (mirrorToFiles) {
    NSString *mirrorPath = nil;
    stdOutConsumer = [mirrorLogger logConsumptionToFile:stdOutConsumer outputKind:@"out" udid:uuid filePathOut:&mirrorPath];
    [logger logFormat:@"Mirroring xctest stdout to %@", mirrorPath];
  }

  // Setup the stderr reader.
  id<FBFileConsumer> stdErrConsumer = [FBLineFileConsumer asynchronousReaderWithQueue:self.executor.workQueue consumer:^(NSString *line){
    [reporter testHadOutput:[line stringByAppendingString:@"\n"]];
    if (mirrorToLogger) {
      [mirrorLogger logFormat:@"[Test Output(err)] %@", line];
    }
  }];
  if (mirrorToFiles) {
    NSString *mirrorPath = nil;
    stdErrConsumer = [mirrorLogger logConsumptionToFile:stdErrConsumer outputKind:@"err" udid:uuid filePathOut:&mirrorPath];
    [logger logFormat:@"Mirroring xctest stderr to %@", mirrorPath];
  }

  // Setup the reader of the shim
  FBLineFileConsumer *otestShimLineConsumer = [FBLineFileConsumer asynchronousReaderWithQueue:self.executor.workQueue dataConsumer:^(NSData *line) {
    [reporter handleEventJSONData:line];
    if (mirrorToLogger) {
      NSString *stringLine = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
      [mirrorLogger logFormat:@"[Shim StdOut] %@", stringLine];
    }
  }];

  id<FBFileConsumer> otestShimConsumer = otestShimLineConsumer;
  if (mirrorToFiles) {
    // Mirror the output
    NSString *mirrorPath = nil;
    otestShimConsumer = [mirrorLogger logConsumptionToFile:otestShimLineConsumer outputKind:@"shim" udid:uuid filePathOut:&mirrorPath];
    [logger logFormat:@"Mirroring shim-fifo output to %@", mirrorPath];
  }

  // Construct and start the process
  return [[[self
    testProcessWithLaunchPath:launchPath arguments:arguments environment:environment stdOutConsumer:stdOutConsumer stdErrConsumer:stdErrConsumer]
    startWithTimeout:self.configuration.testTimeout]
    onQueue:self.executor.workQueue fmap:^(FBLaunchedProcess *processInfo) {
      return [self
        completeLaunchedProcess:processInfo
        otestShimOutputPath:otestShimOutputPath
        otestShimConsumer:otestShimConsumer
        otestShimLineConsumer:otestShimLineConsumer];
    }];
}

#pragma mark Private

- (FBFuture<NSNull *> *)completeLaunchedProcess:(FBLaunchedProcess *)processInfo otestShimOutputPath:(NSString *)otestShimOutputPath otestShimConsumer:(id<FBFileConsumer>)otestShimConsumer otestShimLineConsumer:(FBLineFileConsumer *)otestShimLineConsumer
{
  id<FBLogicXCTestReporter> reporter = self.reporter;
  dispatch_queue_t queue = self.executor.workQueue;

  return [[[[[FBLogicTestRunStrategy
    fromQueue:queue waitForDebuggerToBeAttached:self.configuration.waitForDebugger forProcessIdentifier:processInfo.processIdentifier reporter:reporter]
    onQueue:queue fmap:^(id _) {
      return [FBFileReader readerWithFilePath:otestShimOutputPath consumer:otestShimConsumer];
    }]
    onQueue:queue fmap:^(FBFileReader *reader) {
      return [[reader startReading] mapReplace:reader];
    }]
    onQueue:queue fmap:^(FBFileReader *reader) {
      return [FBLogicTestRunStrategy onQueue:queue waitForExit:processInfo closingReader:reader consumer:otestShimLineConsumer];
    }]
    onQueue:queue map:^(id _) {
      [reporter didFinishExecutingTestPlan];
      return NSNull.null;
    }];
}

+ (FBFuture<NSNull *> *)onQueue:(dispatch_queue_t)queue waitForExit:(FBLaunchedProcess *)process closingReader:(FBFileReader *)reader consumer:(FBLineFileConsumer *)consumer
{
  return [process.exitCode onQueue:queue fmap:^(NSNumber *exitCode) {
    return [FBFuture futureWithFutures:@[
      [reader stopReading],
      [consumer eofHasBeenReceived],
    ]];
  }];
}

+ (FBFuture<NSNull *> *)fromQueue:(dispatch_queue_t)queue waitForDebuggerToBeAttached:(BOOL)waitFor forProcessIdentifier:(pid_t)processIdentifier reporter:(id<FBLogicXCTestReporter>)reporter
{
  if (!waitFor) {
    return [FBFuture futureWithResult:NSNull.null];
  }

  // Report from the current queue, but wait in a special queue.
  dispatch_queue_t waitQueue = dispatch_queue_create("com.facebook.xctestbootstrap.debugger_wait", DISPATCH_QUEUE_SERIAL);
  [reporter processWaitingForDebuggerWithProcessIdentifier:processIdentifier];
  return [[FBFuture
    onQueue:waitQueue resolve:^{
      // If wait_for_debugger is passed, the child process receives SIGSTOP after immediately launch.
      // We wait until it receives SIGCONT from an attached debugger.
      waitid(P_PID, (id_t)processIdentifier, NULL, WCONTINUED);
      [reporter debuggerAttached];

      return [FBFuture futureWithResult:NSNull.null];
    }]
    onQueue:queue map:^(id _) {
      [reporter debuggerAttached];
      return NSNull.null;
    }];
}

- (FBXCTestProcess *)testProcessWithLaunchPath:(NSString *)launchPath arguments:(NSArray<NSString *> *)arguments environment:(NSDictionary<NSString *, NSString *> *)environment stdOutConsumer:(id<FBFileConsumer>)stdOutConsumer stdErrConsumer:(id<FBFileConsumer>)stdErrConsumer
{
  return [FBXCTestProcess
    processWithLaunchPath:launchPath
    arguments:arguments
    environment:[self.configuration buildEnvironmentWithEntries:environment]
    waitForDebugger:self.configuration.waitForDebugger
    stdOutConsumer:stdOutConsumer
    stdErrConsumer:stdErrConsumer
    executor:self.executor];
}

@end
