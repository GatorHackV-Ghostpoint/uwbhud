import { useCallback, useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { requireNativeModule } from 'expo';

export type BroadcastStatus = { state: string; message?: string };
const native = requireNativeModule('UwbAr');
// A permanent server domain can replace this temporary demo origin in one place.
export const SERVER = 'https://parents-costumes-eco-threshold.trycloudflare.com';
const STREAMS = ['hud', 'hud2', 'hud3', 'hud4'];

export type Broadcast = {
  status: BroadcastStatus;
  /** Server / slot line, e.g. "Phone 2" once a slot is assigned. */
  slot: string;
  pending: boolean;
  /** The slot lease while broadcasting; also identifies this phone for the shared waypoint. */
  device: string | null;
  active: boolean;
  checkServer: () => void;
  toggle: () => Promise<void>;
};

/**
 * Broadcast state, owned by App rather than the panel: the panel lives in the pairing sheet, which unmounts when
 * closed, and closing it mustn't stop a running broadcast. Nothing contacts the server until the Broadcast tab
 * is opened (checkServer) or Start is tapped.
 */
export function useBroadcast(): Broadcast {
  const [status, setStatus] = useState<BroadcastStatus>({ state: 'stopped' });
  const [slot, setSlot] = useState('Automatic phone slot');
  const [pending, setPending] = useState(false);
  const [device, setDevice] = useState<string | null>(null);
  const lease = useRef<string | null>(null);
  const mounted = useRef(true);
  const request = useRef<AbortController | null>(null);
  const active = !['stopped', 'error'].includes(status.state);
  const release = useCallback(() => {
    const token = lease.current;
    lease.current = null;
    if (mounted.current) setDevice(null);
    if (token) void fetch(SERVER + '/broadcast/release', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ lease: token }),
    }).catch(() => {});
  }, []);
  useEffect(() => {
    mounted.current = true;
    const subscription = native.addListener('onBroadcastStatus', (event: BroadcastStatus) => {
      if (!mounted.current) return;
      setStatus(event);
      if (['stopped', 'error'].includes(event.state)) release();
    });
    return () => {
      mounted.current = false;request.current?.abort();subscription.remove();
      void native.stopBroadcast();release();
    };
  }, [release]);
  const checkServer = useCallback(() => {
    if (lease.current) return;   // already holding a slot: keep showing it
    setSlot('Checking server…');
    void fetch(SERVER + '/broadcast/slots').then(response => {
      if (!response.ok) throw new Error();
      if (mounted.current && !lease.current) setSlot('Server ready · automatic phone slot');
    }).catch(() => { if (mounted.current && !lease.current) setSlot('Server unavailable · tap Start to retry'); });
  }, []);
  const toggle = useCallback(async () => {
    setPending(true);
    try {
      if (active) { await native.stopBroadcast();release(); }
      else {
        setStatus({ state: 'assigning' });
        const controller = new AbortController();request.current = controller;
        const deadline = setTimeout(() => controller.abort(), 15000);
        let response: Response;
        try { response = await fetch(SERVER + '/broadcast/claim', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}', signal: controller.signal }); }
        finally { clearTimeout(deadline);request.current = null; }
        const assignment = await response.json();
        if (!response.ok) throw new Error(assignment.error || 'Could not assign a phone slot.');
        lease.current = assignment.lease;
        if (mounted.current) setDevice(assignment.lease);
        if (!mounted.current) { release();return; }
        if (!STREAMS.map(s => `/media/${s}/whip`).includes(assignment.path)) {
          throw new Error('Server returned an invalid phone slot.');
        }
        setSlot('Phone ' + (STREAMS.indexOf(assignment.stream) + 1));
        await native.startBroadcast(SERVER + assignment.path, '');
      }
    } catch (error) {
      release();
      if (mounted.current) setStatus({ state: 'error', message: error instanceof Error ? error.message : 'Broadcast failed' });
    } finally { if (mounted.current) setPending(false); }
  }, [active, release]);
  return { status, slot, pending, device, active, checkServer, toggle };
}

const STATE_LABEL: Record<string, string> = {
  stopped: 'Not broadcasting', assigning: 'Getting a phone slot…', starting: 'Starting screen capture…',
  connecting: 'Connecting to the dashboard…', live: 'Live on the dashboard', reconnecting: 'Reconnecting…',
  error: 'Broadcast failed',
};

/** Broadcast tab of the pairing sheet, styled to match it. */
export function BroadcastPanel({ broadcast }: { broadcast: Broadcast }) {
  const { status, slot, pending, active, checkServer, toggle } = broadcast;
  useEffect(() => { checkServer(); }, [checkServer]);   // opening the tab is when we first talk to the server
  const dot = status.state === 'live' ? styles.dotLive
    : status.state === 'error' ? styles.dotError
      : active ? styles.dotBusy : null;
  return (
    <View>
      <Text style={styles.hint}>
        Shares this screen (camera, markers and tags) with the GhostPoint dashboard. Video only, no audio.
      </Text>

      <View style={styles.statusRow}>
        <View style={[styles.dot, dot]} />
        <Text style={styles.statusText}>
          {STATE_LABEL[status.state] ?? status.state}
          {status.message ? ` · ${status.message}` : ''}
        </Text>
      </View>
      <Text style={styles.slot}>{slot}</Text>

      <Pressable
        accessibilityRole="button"
        disabled={pending}
        onPress={() => void toggle()}
        style={[styles.button, active && styles.buttonStop, pending && styles.buttonDisabled]}
      >
        <Text style={styles.buttonText}>{active ? 'Stop broadcast' : 'Start broadcast'}</Text>
      </Pressable>
      {!active && <Text style={styles.hint}>iOS asks to allow screen recording when you start.</Text>}
    </View>
  );
}

// Same palette and sizes as the pairing sheet in App.tsx.
const styles = StyleSheet.create({
  hint: { color: '#ccc', fontSize: 14, marginTop: 4 },
  statusRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 14 },
  dot: { width: 10, height: 10, borderRadius: 5, backgroundColor: '#636366' },
  dotLive: { backgroundColor: '#ff3b30' },
  dotBusy: { backgroundColor: '#ffcc00' },
  dotError: { backgroundColor: '#ff9500' },
  statusText: { color: 'white', fontSize: 16, fontWeight: '700', flexShrink: 1 },
  slot: { color: '#aaa', fontSize: 13, marginTop: 4 },
  button: {
    minHeight: 44, borderRadius: 10, backgroundColor: '#34c759', marginTop: 14,
    alignItems: 'center', justifyContent: 'center', paddingHorizontal: 12,
  },
  buttonStop: { backgroundColor: '#ff3b30' },
  buttonDisabled: { opacity: 0.4 },
  buttonText: { color: 'white', fontSize: 15, fontWeight: '700' },
});
