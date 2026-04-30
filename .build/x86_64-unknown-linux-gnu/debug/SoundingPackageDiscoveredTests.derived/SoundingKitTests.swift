import XCTest
@testable import SoundingKitTests

fileprivate extension AdMarkerEncodingTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__AdMarkerEncodingTests = [
        ("testBreakDurationIsExcludedFromTopLevelJSONButAllowedInFields", testBreakDurationIsExcludedFromTopLevelJSONButAllowedInFields),
        ("testDefaultContainersAreIndependentAcrossInstances", testDefaultContainersAreIndependentAcrossInstances),
        ("testFullyPopulatedMarkerEncodesSemanticContract", testFullyPopulatedMarkerEncodesSemanticContract),
        ("testNilOptionalsEncodeAsExplicitNulls", testNilOptionalsEncodeAsExplicitNulls),
        ("testSnakeCaseKeysAreAbsent", testSnakeCaseKeysAreAbsent)
    ]
}

fileprivate extension HLSManifestMarkerTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__HLSManifestMarkerTests = [
        ("testBinaryManifestTagAttachesToMediaSequenceSegment", testBinaryManifestTagAttachesToMediaSequenceSegment),
        ("testDirectCueTagsEmitUnknownManifestMarkersWithDirectFields", testDirectCueTagsEmitUnknownManifestMarkersWithDirectFields),
        ("testMalformedAndNegativeMediaSequenceNormalizeToZero", testMalformedAndNegativeMediaSequenceNormalizeToZero),
        ("testMalformedBinaryPayloadThrowsRedactedDecodePhaseMonitorError", testMalformedBinaryPayloadThrowsRedactedDecodePhaseMonitorError),
        ("testMultiplePendingTagsAttachToOneSegmentAndResetBeforeNextSegment", testMultiplePendingTagsAttachToOneSegmentAndResetBeforeNextSegment),
        ("testOrphanPendingTagsAreIgnoredWithoutMediaSegment", testOrphanPendingTagsAreIgnoredWithoutMediaSegment)
    ]
}

fileprivate extension HLSManifestParserTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__HLSManifestParserTests = [
        ("testIgnoresUnsupportedAndEmptyMarkerLines", testIgnoresUnsupportedAndEmptyMarkerLines),
        ("testMalformedAttributesDoNotCrashOrLeakWholeInput", testMalformedAttributesDoNotCrashOrLeakWholeInput),
        ("testParsesBareExtXSCTE35PayloadPreservingPadding", testParsesBareExtXSCTE35PayloadPreservingPadding),
        ("testParsesCueOutContSCTE35Payload", testParsesCueOutContSCTE35Payload),
        ("testParsesDateRangeSCTE35In", testParsesDateRangeSCTE35In),
        ("testParsesDateRangeSCTE35OutWithQuotedCommas", testParsesDateRangeSCTE35OutWithQuotedCommas),
        ("testParsesDirectCueInWithoutPayload", testParsesDirectCueInWithoutPayload),
        ("testParsesDirectCueOutWithAttributes", testParsesDirectCueOutWithAttributes),
        ("testParsesDirectCueOutWithDuration", testParsesDirectCueOutWithDuration),
        ("testParsesDirectCueOutWithoutPayload", testParsesDirectCueOutWithoutPayload),
        ("testParsesExtOatclsSCTE35Payload", testParsesExtOatclsSCTE35Payload),
        ("testParsesExtXSCTE35CueAttributePayload", testParsesExtXSCTE35CueAttributePayload)
    ]
}

fileprivate extension HLSMonitorAdapterTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__HLSMonitorAdapterTests = [
        ("testAdapterEmitsManifestMarkersBeforeSegmentMarkersForSameMediaSequence", asyncTest(testAdapterEmitsManifestMarkersBeforeSegmentMarkersForSameMediaSequence)),
        ("testLoaderFailuresWrapAsIngestPhaseMonitorErrorWithRedactedContext", asyncTest(testLoaderFailuresWrapAsIngestPhaseMonitorErrorWithRedactedContext)),
        ("testLocalSegmentLoaderResolvesManifestRelativeURI", asyncTest(testLocalSegmentLoaderResolvesManifestRelativeURI)),
        ("testPipelineAutoDetectionTreatsM3U8HTTPURLsAsHLSWithoutLoadingInTest", testPipelineAutoDetectionTreatsM3U8HTTPURLsAsHLSWithoutLoadingInTest),
        ("testPipelineAutoDetectsLocalM3U8FixtureAsHLS", asyncTest(testPipelineAutoDetectsLocalM3U8FixtureAsHLS)),
        ("testPipelineAutoNonHLSRemainsUnsupported", asyncTest(testPipelineAutoNonHLSRemainsUnsupported)),
        ("testPipelinePropagatesHLSAdapterErrorsWithoutRewriting", asyncTest(testPipelinePropagatesHLSAdapterErrorsWithoutRewriting)),
        ("testPipelineRunsHLSFixtureAndAppliesMarkerTypeFilter", asyncTest(testPipelineRunsHLSFixtureAndAppliesMarkerTypeFilter)),
        ("testSegmentExtractionFailuresWrapAsDecodePhaseMonitorErrorWithRedactedContext", asyncTest(testSegmentExtractionFailuresWrapAsDecodePhaseMonitorErrorWithRedactedContext)),
        ("testSegmentWithoutCandidateEmitsNoSegmentMarker", asyncTest(testSegmentWithoutCandidateEmitsNoSegmentMarker))
    ]
}

fileprivate extension ID3TagScannerTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__ID3TagScannerTests = [
        ("testDescriptionsContainOnlySanitizedFailureClassAndContext", testDescriptionsContainOnlySanitizedFailureClassAndContext),
        ("testEmptyAndNoID3BytesReturnNoTags", testEmptyAndNoID3BytesReturnNoTags),
        ("testExactEndOfInputTagIsAccepted", testExactEndOfInputTagIsAccepted),
        ("testFooterFlagAddsTenBytesToFullTagRange", testFooterFlagAddsTenBytesToFullTagRange),
        ("testFooterFlagWithoutFooterBytesThrowsTruncatedTag", testFooterFlagWithoutFooterBytesThrowsTruncatedTag),
        ("testMaxSizeRejectionThrowsSanitizedScanError", testMaxSizeRejectionThrowsSanitizedScanError),
        ("testMultipleCompleteTagsAreReturnedInByteOrder", testMultipleCompleteTagsAreReturnedInByteOrder),
        ("testNonSynchsafeTagSizeByteThrowsSanitizedScanError", testNonSynchsafeTagSizeByteThrowsSanitizedScanError),
        ("testPrefixAndSuffixBytesAreExcludedFromReturnedTagRange", testPrefixAndSuffixBytesAreExcludedFromReturnedTagRange),
        ("testRepeatedFakeMagicAdvancesDeterministicallyToLaterValidTag", testRepeatedFakeMagicAdvancesDeterministicallyToLaterValidTag),
        ("testTagAtOffsetZeroReturnsCompleteTag", testTagAtOffsetZeroReturnsCompleteTag),
        ("testTruncatedDeclaredTagBodyThrowsSanitizedScanError", testTruncatedDeclaredTagBodyThrowsSanitizedScanError),
        ("testTruncatedHeaderThrowsWhenID3CandidateStartsNearEnd", testTruncatedHeaderThrowsWhenID3CandidateStartsNearEnd),
        ("testUnsupportedMajorVersionThrowsSanitizedScanError", testUnsupportedMajorVersionThrowsSanitizedScanError)
    ]
}

fileprivate extension MonitorOptionsTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__MonitorOptionsTests = [
        ("testFilterIncludesCentralizesMarkerMatchingSemantics", testFilterIncludesCentralizesMarkerMatchingSemantics),
        ("testNormalizesAdAndClassificationFilters", testNormalizesAdAndClassificationFilters),
        ("testNormalizesStreamTypesAndMarkerFilters", testNormalizesStreamTypesAndMarkerFilters),
        ("testPipelineKeepsUnsupportedTypesAsRedactedNotImplementedErrors", asyncTest(testPipelineKeepsUnsupportedTypesAsRedactedNotImplementedErrors)),
        ("testRejectsNegativeTimeoutBeforeRuntime", testRejectsNegativeTimeoutBeforeRuntime),
        ("testRejectsUnknownFilterInSoundingKit", testRejectsUnknownFilterInSoundingKit)
    ]
}

fileprivate extension SCTE35DecoderTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__SCTE35DecoderTests = [
        ("testDescriptorRecordsAreBoundedByDescriptorLoopLength", testDescriptorRecordsAreBoundedByDescriptorLoopLength),
        ("testMalformedSectionsThrowSanitizedErrors", testMalformedSectionsThrowSanitizedErrors),
        ("testSpliceInsertWithProgramSpliceAndBreakDurationDecodesFixtureCriticalFields", testSpliceInsertWithProgramSpliceAndBreakDurationDecodesFixtureCriticalFields),
        ("testSpliceNullDecodesHeaderAndCommandFields", testSpliceNullDecodesHeaderAndCommandFields),
        ("testSpliceNullHexDecodesToSameCanonicalRawBase64", testSpliceNullHexDecodesToSameCanonicalRawBase64),
        ("testUnsupportedAndEncryptedSectionsThrowSanitizedErrors", testUnsupportedAndEncryptedSectionsThrowSanitizedErrors),
        ("testWidePtsAndDurationConvertWithoutIntOverflow", testWidePtsAndDurationConvertWithoutIntOverflow)
    ]
}

fileprivate extension SCTE35FixtureTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__SCTE35FixtureTests = [
        ("testBase64HexAndBinaryFacadeDecodeEquivalentFixtureMarkerSemantics", testBase64HexAndBinaryFacadeDecodeEquivalentFixtureMarkerSemantics),
        ("testDecodeSectionRejectsTruncatedBinaryWithoutPayloadLeakage", testDecodeSectionRejectsTruncatedBinaryWithoutPayloadLeakage),
        ("testFacadeErrorsAreSanitizedForMalformedStringPayloadsAndSecretSources", testFacadeErrorsAreSanitizedForMalformedStringPayloadsAndSecretSources)
    ]
}

fileprivate extension SCTE35MarkerMappingTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__SCTE35MarkerMappingTests = [
        ("testHexAndBase64VariantsProduceEquivalentMarkerSemantics", testHexAndBase64VariantsProduceEquivalentMarkerSemantics),
        ("testMalformedDescriptorLoopAndTruncatedSegmentationDescriptorThrowSanitizedErrors", testMalformedDescriptorLoopAndTruncatedSegmentationDescriptorThrowSanitizedErrors),
        ("testSegmentationDescriptorMapsDescriptorContentAndFields", testSegmentationDescriptorMapsDescriptorContentAndFields),
        ("testSemanticJSONDoesNotExposeTopLevelBreakDurationKeys", testSemanticJSONDoesNotExposeTopLevelBreakDurationKeys),
        ("testSpliceInsertMapsFixtureCriticalFieldSemantics", testSpliceInsertMapsFixtureCriticalFieldSemantics),
        ("testSpliceNullMapsToUnknownSCTE35MarkerWithCommandNameField", testSpliceNullMapsToUnknownSCTE35MarkerWithCommandNameField)
    ]
}

fileprivate extension SCTE35PayloadTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__SCTE35PayloadTests = [
        ("testBase64InputNormalizesToCanonicalBytesAndRawBase64", testBase64InputNormalizesToCanonicalBytesAndRawBase64),
        ("testBitReaderReadsAcrossByteBoundaries", testBitReaderReadsAcrossByteBoundaries),
        ("testBitReaderSupportsWideReadsAndZeroWidthReads", testBitReaderSupportsWideReadsAndZeroWidthReads),
        ("testBitReaderUnderrunThrowsSanitizedError", testBitReaderUnderrunThrowsSanitizedError),
        ("testDataInputNormalizesToCanonicalRawBase64", testDataInputNormalizesToCanonicalRawBase64),
        ("testEmptyDataThrowsSanitizedError", testEmptyDataThrowsSanitizedError),
        ("testHexInputsNormalizeToSameCanonicalBase64AsBase64", testHexInputsNormalizeToSameCanonicalBase64AsBase64),
        ("testMalformedInputsThrowSanitizedErrors", testMalformedInputsThrowSanitizedErrors)
    ]
}

fileprivate extension SoundingKitTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__SoundingKitTests = [
        ("testSoundingKitVersionIdentifiesTheLibrary", testSoundingKitVersionIdentifiesTheLibrary)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __SoundingKitTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(AdMarkerEncodingTests.__allTests__AdMarkerEncodingTests),
        testCase(HLSManifestMarkerTests.__allTests__HLSManifestMarkerTests),
        testCase(HLSManifestParserTests.__allTests__HLSManifestParserTests),
        testCase(HLSMonitorAdapterTests.__allTests__HLSMonitorAdapterTests),
        testCase(ID3TagScannerTests.__allTests__ID3TagScannerTests),
        testCase(MonitorOptionsTests.__allTests__MonitorOptionsTests),
        testCase(SCTE35DecoderTests.__allTests__SCTE35DecoderTests),
        testCase(SCTE35FixtureTests.__allTests__SCTE35FixtureTests),
        testCase(SCTE35MarkerMappingTests.__allTests__SCTE35MarkerMappingTests),
        testCase(SCTE35PayloadTests.__allTests__SCTE35PayloadTests),
        testCase(SoundingKitTests.__allTests__SoundingKitTests)
    ]
}