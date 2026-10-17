package keeper

// EventKind says what an Event carries.
type EventKind int

const (
	// EventData carries output bytes starting at Offset.
	EventData EventKind = iota + 1
	// EventSkipped says output before SkippedTo is gone; the stream resumes there.
	EventSkipped
	// EventExited says the program ended, with how in Exit. Nothing follows it.
	EventExited
)

// Event is one step of a terminal's output stream.
type Event struct {
	Kind      EventKind
	Offset    uint64
	Data      []byte
	SkippedTo uint64
	Exit      *Exit
}
