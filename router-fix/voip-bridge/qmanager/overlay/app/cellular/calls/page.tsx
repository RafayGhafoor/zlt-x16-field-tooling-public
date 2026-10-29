import CallsComponent from "@/components/cellular/calls/calls";

// The route file is deliberately thin, exactly like its siblings under
// `/cellular/`: it re-exports a client shell and holds no markup of its own.
//
// The shell has to be a client component (it owns a WebRTC peer, a microphone
// stream and a 1 s poll), and the page header is inside it so that it takes part
// in the same motion cascade as the cards below.
const CallsPage = () => {
  return <CallsComponent />;
};

export default CallsPage;
