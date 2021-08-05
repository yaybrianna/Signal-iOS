//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import <SignalServiceKit/SSKJobRecord.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSErrorDomain const SSKJobRecordErrorDomain = @"SignalServiceKit.JobRecord";

#pragma mark -

@interface SSKJobRecord ()

@property (nonatomic) SSKJobRecordStatus status;
@property (nonatomic) UInt64 sortId;
@property (nonatomic, nullable) NSNumber *exclusiveProcessIdentifier;

@end

#pragma mark -

@implementation SSKJobRecord

- (instancetype)initWithLabel:(NSString *)label
{
    self = [super init];
    if (!self) {
        return self;
    }

    _status = SSKJobRecordStatus_Ready;
    _label = label;

    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    return [super initWithCoder:coder];
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
      exclusiveProcessIdentifier:(nullable NSNumber *)exclusiveProcessIdentifier
                    failureCount:(NSUInteger)failureCount
                           label:(NSString *)label
                          sortId:(unsigned long long)sortId
                          status:(SSKJobRecordStatus)status
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId];

    if (!self) {
        return self;
    }

    _exclusiveProcessIdentifier = exclusiveProcessIdentifier;
    _failureCount = failureCount;
    _label = label;
    _sortId = sortId;
    _status = status;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

#pragma mark - TSYapDatabaseObject Overrides

+ (NSString *)collection
{
    // To avoid a plethora of identical JobRecord subclasses, all job records share
    // a common collection and JobQueue's distinguish their behavior by the job's
    // `label`
    return @"JobRecord";
}

#pragma mark -

- (void)flagAsExclusiveForCurrentProcessIdentifier
{
    self.exclusiveProcessIdentifier = @(NSProcessInfo.processInfo.processIdentifier);
}

- (void)updateWithExclusiveForCurrentProcessIdentifierWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [self anyUpdateWithTransaction:transaction
                             block:^(SSKJobRecord *record) { [record flagAsExclusiveForCurrentProcessIdentifier]; }];
}

- (void)updateStatus:(SSKJobRecordStatus)status transaction:(SDSAnyWriteTransaction *)transaction
{
    [self anyUpdateWithTransaction:transaction
                             block:^(SSKJobRecord *record) {
                                 record.status = status;
                             }];
}

- (BOOL)saveAsStartedWithTransaction:(SDSAnyWriteTransaction *)transaction error:(NSError **)outError
{
    if (self.status != SSKJobRecordStatus_Ready) {
        *outError =
            [NSError errorWithDomain:SSKJobRecordErrorDomain code:JobRecordError_IllegalStateTransition userInfo:nil];
        return NO;
    }
    [self updateStatus:SSKJobRecordStatus_Running transaction:transaction];

    return YES;
}

- (void)saveAsPermanentlyFailedWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [self updateStatus:SSKJobRecordStatus_PermanentlyFailed transaction:transaction];
}

- (void)saveAsObsoleteWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [self updateStatus:SSKJobRecordStatus_Obsolete transaction:transaction];
}

- (BOOL)saveRunningAsReadyWithTransaction:(SDSAnyWriteTransaction *)transaction error:(NSError **)outError
{
    switch (self.status) {
        case SSKJobRecordStatus_Running: {
            [self updateStatus:SSKJobRecordStatus_Ready transaction:transaction];
            return YES;
        }
        case SSKJobRecordStatus_Ready:
        case SSKJobRecordStatus_PermanentlyFailed:
        case SSKJobRecordStatus_Obsolete:
        case SSKJobRecordStatus_Unknown: {
            *outError = [NSError errorWithDomain:SSKJobRecordErrorDomain
                                            code:JobRecordError_IllegalStateTransition
                                        userInfo:nil];
            return NO;
        }
    }
}

- (BOOL)addFailureWithWithTransaction:(SDSAnyWriteTransaction *)transaction error:(NSError **)outError
{
    switch (self.status) {
        case SSKJobRecordStatus_Running: {
            [self anyUpdateWithTransaction:transaction
                                     block:^(SSKJobRecord *record) {
                                         record.failureCount = MIN(record.failureCount + 1, INT64_MAX);
                                     }];
            return YES;
        }
        case SSKJobRecordStatus_Ready:
        case SSKJobRecordStatus_PermanentlyFailed:
        case SSKJobRecordStatus_Obsolete:
        case SSKJobRecordStatus_Unknown: {
            *outError = [NSError errorWithDomain:SSKJobRecordErrorDomain
                                            code:JobRecordError_IllegalStateTransition
                                        userInfo:nil];
            return NO;
        }
    }
}

@end

NS_ASSUME_NONNULL_END
