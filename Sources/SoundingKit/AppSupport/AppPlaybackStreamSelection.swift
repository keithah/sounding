import Foundation

public actor AppPlaybackStreamSelection {
    private var selectedStreamID: Int64?

    public init(selectedStreamID: Int64? = nil) {
        self.selectedStreamID = selectedStreamID
    }

    public func select(streamID: Int64?) {
        selectedStreamID = streamID
    }

    public func clear(ifStreamID streamID: Int64) {
        if selectedStreamID == streamID {
            selectedStreamID = nil
        }
    }

    public func isSelected(streamID: Int64) -> Bool {
        selectedStreamID == streamID
    }
}
