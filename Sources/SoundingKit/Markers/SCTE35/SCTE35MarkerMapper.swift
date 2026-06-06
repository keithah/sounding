import Foundation

/// Maps decoded SCTE-35 cues into SoundingKit's tidemark-compatible marker boundary.
public enum SCTE35MarkerMapper {
    public static func map(
        _ input: SCTE35PayloadInput,
        source: String,
        tag: String? = nil,
        segment: String? = nil,
        timestamp: String? = nil
    ) throws -> AdMarker {
        let cue = try SCTE35Decoder.decode(input)
        return map(cue, source: source, tag: tag, segment: segment, timestamp: timestamp)
    }

    public static func map(
        _ cue: SCTE35Cue,
        source: String,
        tag: String? = nil,
        segment: String? = nil,
        timestamp: String? = nil
    ) -> AdMarker {
        var fields: [String: JSONValue] = [
            "CommandName": .string(commandFieldName(for: cue))
        ]

        if let eventID = cue.spliceEventID {
            fields["SpliceEventID"] = .string(hex(eventID, width: 8))
        }
        if let outOfNetworkIndicator = cue.outOfNetworkIndicator {
            fields["OutOfNetworkIndicator"] = .string(outOfNetworkIndicator ? "true" : "false")
        }
        if let breakDuration = cue.breakDuration {
            fields["BreakDuration"] = .string(formatSeconds(breakDuration))
        }

        let descriptorValues = cue.descriptors.map { descriptorJSON($0, fields: &fields) }

        return AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: source,
            tag: tag,
            pts: cue.ptsTime,
            segment: segment,
            rawBase64: cue.rawBase64,
            command: commandJSON(for: cue),
            descriptors: descriptorValues,
            fields: fields,
            timestamp: timestamp,
            breakDuration: cue.breakDuration
        )
    }

    private static func commandJSON(for cue: SCTE35Cue) -> JSONValue {
        var object: [String: JSONValue] = [
            "Name": .string(cue.commandName),
            "Type": .string(hex(cue.spliceCommandType, width: 2))
        ]
        if let eventID = cue.spliceEventID {
            object["SpliceEventID"] = .string(hex(eventID, width: 8))
        }
        if let outOfNetworkIndicator = cue.outOfNetworkIndicator {
            object["OutOfNetworkIndicator"] = .bool(outOfNetworkIndicator)
        }
        if let pts = cue.ptsTime {
            object["PTS"] = .number(round(pts, places: 6))
        }
        if let breakDuration = cue.breakDuration {
            object["BreakDuration"] = .number(round(breakDuration, places: 6))
        }
        return .object(object)
    }

    private static func descriptorJSON(
        _ descriptor: SCTE35Descriptor,
        fields: inout [String: JSONValue]
    ) -> JSONValue {
        guard let segmentation = descriptor.segmentation else {
            var object: [String: JSONValue] = [
                "Tag": .string("UnknownSpliceDescriptor"),
                "DescriptorTag": .string(hex(descriptor.tag, width: 2)),
                "Length": .number(Double(descriptor.length))
            ]
            if let identifier = descriptor.identifier {
                object["Identifier"] = .string(identifier)
            }
            return .object(object)
        }

        fields["SegmentationEventID"] = .string(hex(segmentation.segmentationEventID, width: 8))
        if let segmentationTypeID = segmentation.segmentationTypeID {
            fields["SegmentationTypeID"] = .string(hex(segmentationTypeID, width: 2))
            if let name = segmentationTypeName(for: segmentationTypeID) {
                fields["SegmentationTypeName"] = .string(name)
                fields["Title"] = .string(name)
            }
        }
        if let upidType = segmentation.segmentationUPIDType {
            fields["SegmentationUPIDType"] = .string(hex(upidType, width: 2))
        }
        if let upid = segmentation.segmentationUPID {
            fields["SegmentationUPID"] = .string(upid)
        }
        if let duration = segmentation.segmentationDuration {
            fields["SegmentationDuration"] = .string(formatSeconds(duration))
        }

        var object: [String: JSONValue] = [
            "Tag": .string("SegmentationDescriptor"),
            "DescriptorTag": .string(hex(descriptor.tag, width: 2)),
            "Identifier": .string(segmentation.identifier),
            "SegmentationEventID": .string(hex(segmentation.segmentationEventID, width: 8)),
            "SegmentationEventCancelIndicator": .bool(segmentation.segmentationEventCancelIndicator)
        ]

        addOptionalBool(segmentation.programSegmentationFlag, key: "ProgramSegmentationFlag", to: &object)
        addOptionalBool(segmentation.segmentationDurationFlag, key: "SegmentationDurationFlag", to: &object)
        addOptionalBool(segmentation.deliveryNotRestrictedFlag, key: "DeliveryNotRestrictedFlag", to: &object)
        addOptionalBool(segmentation.webDeliveryAllowedFlag, key: "WebDeliveryAllowedFlag", to: &object)
        addOptionalBool(segmentation.noRegionalBlackoutFlag, key: "NoRegionalBlackoutFlag", to: &object)
        addOptionalBool(segmentation.archiveAllowedFlag, key: "ArchiveAllowedFlag", to: &object)
        if let deviceRestrictions = segmentation.deviceRestrictions {
            object["DeviceRestrictions"] = .number(Double(deviceRestrictions))
        }
        addOptionalNumber(segmentation.segmentationDuration, key: "SegmentationDuration", to: &object)
        if let upidType = segmentation.segmentationUPIDType {
            object["SegmentationUPIDType"] = .string(hex(upidType, width: 2))
        }
        if let upid = segmentation.segmentationUPID {
            object["SegmentationUPID"] = .string(upid)
        }
        if let segmentationTypeID = segmentation.segmentationTypeID {
            object["SegmentationTypeID"] = .string(hex(segmentationTypeID, width: 2))
            if let name = segmentationTypeName(for: segmentationTypeID) {
                object["SegmentationTypeName"] = .string(name)
            }
        }
        if let segmentNumber = segmentation.segmentNumber {
            object["SegmentNumber"] = .number(Double(segmentNumber))
        }
        if let segmentsExpected = segmentation.segmentsExpected {
            object["SegmentsExpected"] = .number(Double(segmentsExpected))
        }
        if let subSegmentNumber = segmentation.subSegmentNumber {
            object["SubSegmentNumber"] = .number(Double(subSegmentNumber))
        }
        if let subSegmentsExpected = segmentation.subSegmentsExpected {
            object["SubSegmentsExpected"] = .number(Double(subSegmentsExpected))
        }

        return .object(object)
    }

    private static func commandFieldName(for cue: SCTE35Cue) -> String {
        switch cue.spliceCommandType {
        case 0x00:
            return "SPLICE_NULL"
        case 0x05:
            if cue.outOfNetworkIndicator == true {
                return "SPLICE_INSERT_OON_TRUE"
            } else if cue.outOfNetworkIndicator == false {
                return "SPLICE_INSERT_OON_FALSE"
            } else {
                return "SPLICE_INSERT"
            }
        case 0x06:
            return "TIME_SIGNAL"
        default:
            return cue.commandName.uppercased().replacingOccurrences(of: " ", with: "_")
        }
    }

    private static func segmentationTypeName(for id: UInt8) -> String? {
        switch id {
        case 0x10:
            return "Program start"
        case 0x11:
            return "Program end"
        case 0x20:
            return "Chapter start"
        case 0x21:
            return "Chapter end"
        case 0x22:
            return "Breakaway start"
        case 0x23:
            return "Breakaway end"
        case 0x30:
            return "Provider advertisement start"
        case 0x31:
            return "Provider advertisement end"
        case 0x32:
            return "Distributor advertisement start"
        case 0x33:
            return "Distributor advertisement end"
        case 0x34:
            return "Provider placement opportunity start"
        case 0x35:
            return "Provider placement opportunity end"
        case 0x36:
            return "Distributor placement opportunity start"
        case 0x37:
            return "Distributor placement opportunity end"
        case 0x38:
            return "Provider overlay placement opportunity start"
        case 0x39:
            return "Provider overlay placement opportunity end"
        case 0x40:
            return "Provider unscheduled event start"
        case 0x41:
            return "Provider unscheduled event end"
        case 0x42:
            return "Distributor unscheduled event start"
        case 0x43:
            return "Distributor unscheduled event end"
        case 0x44:
            return "Alternate content opportunity start"
        case 0x45:
            return "Alternate content opportunity end"
        case 0x46:
            return "Provider promo start"
        case 0x47:
            return "Provider promo end"
        case 0x48:
            return "Distributor promo start"
        case 0x49:
            return "Distributor promo end"
        case 0x4A:
            return "Provider network start"
        case 0x4B:
            return "Provider network end"
        case 0x4C:
            return "Distributor network start"
        case 0x4D:
            return "Distributor network end"
        default:
            return nil
        }
    }

    private static func addOptionalBool(_ value: Bool?, key: String, to object: inout [String: JSONValue]) {
        if let value {
            object[key] = .bool(value)
        }
    }

    private static func addOptionalNumber(_ value: Double?, key: String, to object: inout [String: JSONValue]) {
        if let value {
            object[key] = .number(value)
        }
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func round(_ value: Double, places: Int) -> Double {
        let multiplier = pow(10.0, Double(places))
        return (value * multiplier).rounded() / multiplier
    }

    private static func hex(_ value: UInt8, width: Int) -> String {
        String(format: "0x%0\(width)llx", UInt64(value))
    }

    private static func hex(_ value: UInt32, width: Int) -> String {
        String(format: "0x%0\(width)llx", UInt64(value))
    }
}
