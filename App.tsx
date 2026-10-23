import { useMemo, useState } from 'react';
import { StatusBar, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { isUwbSupported, UwbArView, type UwbPeer, type UwbStatus } from './modules/uwb-ar';

// Screen margins the HUD keeps clear (top status bar, bottom panel).
const INSET = { top: 130, bottom: 150, side: 30 };

export default function App() {
  const [peers, setPeers] = useState<UwbPeer[]>([]);
  const [status, setStatus] = useState<UwbStatus | null>(null);
  const name = useMemo(() => 'Phone-' + Math.random().toString(36).slice(2, 6).toUpperCase(), []);
  const supported = useMemo(() => isUwbSupported(), []);

  if (!supported) {
    return (
      <View style={[styles.fill, styles.center]}>
        <Text style={styles.big}>This iPhone has no UWB chip.</Text>
        <Text style={styles.small}>Needs iPhone 11 or newer (not SE).</Text>
      </View>
    );
  }

  const located = peers.filter((p) => p.hasPosition && !p.stale);
  const waiting = peers.filter((p) => !p.hasPosition || p.stale);

  return (
    <View style={styles.fill}>
      <StatusBar barStyle="light-content" />
      <UwbArView
        style={StyleSheet.absoluteFill}
        displayName={name}
        onPeers={(e) => setPeers(e.nativeEvent.peers)}
        onStatus={(e) => setStatus(e.nativeEvent)}
      />

      {located.map((p) => (
        <PeerMarker key={p.id} peer={p} />
      ))}

      <View style={[styles.card, styles.top]}>
        <Text style={styles.cardText}>
          {name} · {status?.status ?? 'Starting…'}
        </Text>
        {status && !status.cameraAssist && (
          <Text style={styles.warn}>No camera assistance on this model: distance only</Text>
        )}
      </View>

      {waiting.length > 0 && (
        <View style={[styles.card, styles.bottom]}>
          {waiting.map((p) => (
            <Text key={p.id} style={styles.cardText}>
              {p.name}: {formatDistance(p.distance)}
              {p.stale ? ' (signal lost)' : `. ${p.guidance ?? 'Finding direction…'}`}
            </Text>
          ))}
        </View>
      )}
    </View>
  );
}

/** Name tag over the person when on screen; arrow pinned to the edge when not. */
function PeerMarker({ peer }: { peer: UwbPeer }) {
  const { width, height } = useWindowDimensions();
  const onScreen =
    peer.inFront &&
    peer.x > INSET.side && peer.x < width - INSET.side &&
    peer.y > INSET.top && peer.y < height - INSET.bottom;

  if (onScreen) {
    return (
      <View pointerEvents="none" style={[styles.tag, { left: peer.x - 70, top: peer.y - 80 }]}>
        <Text style={styles.tagName}>{peer.name}</Text>
        <Text style={styles.tagDist}>{formatDistance(peer.distance)}</Text>
      </View>
    );
  }

  // Walk from screen center along the peer's direction until we hit the safe-area edge.
  const cx = width / 2, cy = height / 2;
  const rx = (width / 2 - INSET.side - 40) / Math.max(Math.abs(peer.dirX), 1e-4);
  const ry = (height / 2 - INSET.top) / Math.max(Math.abs(peer.dirY), 1e-4);
  const r = Math.min(rx, ry);
  const angle = Math.atan2(peer.dirY, peer.dirX); // 0 = right, positive = clockwise (y down)

  return (
    <View pointerEvents="none" style={[styles.edge, { left: cx + peer.dirX * r - 55, top: cy + peer.dirY * r - 30 }]}>
      <Text style={[styles.arrow, { transform: [{ rotate: `${angle}rad` }] }]}>➤</Text>
      <Text style={styles.edgeText}>{peer.name}</Text>
      <Text style={styles.edgeText}>{formatDistance(peer.distance)}</Text>
    </View>
  );
}

function formatDistance(m?: number) {
  if (m == null) return '—';
  return m < 10 ? `${m.toFixed(2)} m` : `${m.toFixed(1)} m`;
}

const styles = StyleSheet.create({
  fill: { flex: 1, backgroundColor: 'black' },
  center: { alignItems: 'center', justifyContent: 'center', padding: 24 },
  big: { color: 'white', fontSize: 20, fontWeight: '700', textAlign: 'center' },
  small: { color: '#ccc', fontSize: 15, marginTop: 8 },
  card: {
    position: 'absolute', left: 12, right: 12,
    backgroundColor: 'rgba(0,0,0,0.55)', borderRadius: 12, padding: 10,
  },
  top: { top: 56 },
  bottom: { bottom: 40 },
  cardText: { color: 'white', fontSize: 14, fontWeight: '600' },
  warn: { color: '#ffcc00', fontSize: 13, marginTop: 4 },
  tag: {
    position: 'absolute', width: 140, alignItems: 'center',
    backgroundColor: 'rgba(52,199,89,0.85)', borderRadius: 12, paddingVertical: 6,
  },
  tagName: { color: 'white', fontSize: 15, fontWeight: '700' },
  tagDist: { color: 'white', fontSize: 13 },
  edge: {
    position: 'absolute', width: 110, alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.6)', borderRadius: 12, paddingVertical: 6,
  },
  arrow: { color: '#34c759', fontSize: 22 },
  edgeText: { color: 'white', fontSize: 12, fontWeight: '600' },
});
