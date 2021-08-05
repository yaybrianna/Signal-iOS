//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import <SignalServiceKit/SSKJobRecord.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSBroadcastMediaMessageJobRecord : SSKJobRecord

@property (class, nonatomic, readonly) NSString *defaultLabel;

/// A map from the AttachmentStream's to upload to their corresponding list of visibile copies in individual
/// conversations. e.g. if we're broadcast-sending a picture and a video to 3 recipients, the dictionary would look
/// like:
///     [
///         pictureAttachmentId: [
///             pictureCopyAttachmentIdForRecipient1,
///             pictureCopyAttachmentIdForRecipient2,
///             pictureCopyAttachmentIdForRecipient3
///         ],
///         videoAttachmentId: [
///             videoCopyAttachmentIdForRecipient1,
///             videoCopyAttachmentIdForRecipient2,
///             videoCopyAttachmentIdForRecipient3
///         ]
///     ]
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray<NSString *> *> *attachmentIdMap;

- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithAttachmentIdMap:(NSDictionary<NSString *, NSArray<NSString *> *> *)attachmentIdMap
                                  label:(NSString *)label NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithLabel:(NSString *)label NS_UNAVAILABLE;

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
                  failureCount:(NSUInteger)failureCount
                         label:(NSString *)label
                        sortId:(unsigned long long)sortId
                        status:(SSKJobRecordStatus)status NS_UNAVAILABLE;

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
                 attachmentIdMap:(NSDictionary<NSString *,NSArray<NSString *> *> *)attachmentIdMap
NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(grdbId:uniqueId:exclusiveProcessIdentifier:failureCount:label:sortId:status:attachmentIdMap:));

// clang-format on

// --- CODE GENERATION MARKER

@end

NS_ASSUME_NONNULL_END
